package com.github.dvbeckwitt.videre.proxy;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Proxy;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.Cookie;
import okhttp3.Headers;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import org.json.JSONObject;

/** Per-verification fixed-origin Tor gateway; never an arbitrary HTTP proxy. */
public final class OnionVerificationGateway implements Closeable {
    private final String host;
    private final String base;
    public static final String GATE_COOKIE = "__videre_verification_gate";
    private static final int REQUEST_LIMIT = 2 * 1024 * 1024;
    private static final int RESPONSE_LIMIT = 8 * 1024 * 1024;
    private static final Set<String> HOP = new HashSet<>(Arrays.asList(
        "connection", "proxy-connection", "keep-alive", "transfer-encoding",
        "te", "trailer", "upgrade", "proxy-authenticate", "proxy-authorization"
    ));
    private static final String[] CAPTURE = {
        "User-Agent", "Accept-Language", "Accept-Encoding", "Accept", "Cookie"
    };

    public interface Listener {
        void onEvent(String safe);
        void onVerified(Map<String, String> requestHeaders, long expiresAt);
    }
    private final String gateToken;
    private final Listener listener;
    private final OkHttpClient client;
    private final Map<String, Cookie> jar = new LinkedHashMap<>();
    private final ExecutorService workers = Executors.newFixedThreadPool(4);
    private final Semaphore active = new Semaphore(4);
    private final Set<Socket> connections = ConcurrentHashMap.newKeySet();
    private final String controlPath = "/.videre-preflight/" + UUID.randomUUID() + "/control";
    private final String policyPath = "/.videre-preflight/" + UUID.randomUUID() + "/policy";
    private final String probePath = "/.videre-preflight/" + UUID.randomUUID() + "/probe";
    private final AtomicInteger probeRequests = new AtomicInteger();
    private ServerSocket server;
    private volatile boolean closed;
    private volatile boolean relayEnabled;
    private volatile String localOrigin;

    public OnionVerificationGateway(String origin, ProxyPolicy policy, String gateToken, Listener listener) {
        String canonical = OnionSessionStoreKt.canonicalOnionOrigin(origin);
        if (canonical == null || !canonical.equals(origin) || !policy.getEnabled()) {
            throw new IllegalArgumentException("Unsupported onion verification");
        }
        this.base = canonical;
        this.host = HttpUrl.get(canonical).host();
        if (gateToken == null || !gateToken.matches("[A-Za-z0-9_-]{16,256}")) {
            throw new IllegalArgumentException("Invalid gate");
        }
        this.gateToken = gateToken;
        this.listener = listener;
        client = new OkHttpClient.Builder()
            .proxy(new Proxy(Proxy.Type.SOCKS,
                InetSocketAddress.createUnresolved(policy.getHost(), policy.getPort())))
            // SOCKS routes use unresolved destination addresses in OkHttp. Any
            // unexpected attempt at app-side DNS fails rather than leaking it.
            .dns(name -> {
                throw new UnknownHostException("Local onion DNS disabled");
            })
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(25, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .callTimeout(45, TimeUnit.SECONDS)
            .build();
    }

    public synchronized int start() throws IOException {
        if (server != null) {
            return server.getLocalPort();
        }
        server = new ServerSocket();
        server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 16);
        localOrigin = "http://localhost:" + server.getLocalPort();
        Thread accept = new Thread(() -> {
            while (!closed) {
                try {
                    Socket connection = server.accept();
                    if (!active.tryAcquire()) {
                        connection.close();
                        continue;
                    }
                    connections.add(connection);
                    try {
                        workers.execute(() -> {
                            try {
                                handle(connection);
                            } finally {
                                connections.remove(connection);
                                active.release();
                            }
                        });
                    } catch (RejectedExecutionException ignored) {
                        connections.remove(connection);
                        active.release();
                        connection.close();
                    }
                } catch (IOException ignored) {
                    if (!closed) {
                        listener.onEvent("Gateway accept failure");
                    }
                }
            }
        }, "onion-loopback-gateway");
        accept.setDaemon(true);
        accept.start();
        return server.getLocalPort();
    }
    public String origin() {
        return localOrigin;
    }

    public String controlUrl() {
        return localOrigin + controlPath;
    }

    public String policyUrl() {
        return localOrigin + policyPath;
    }

    public String probeUrl() {
        return "http://127.0.0.1:" + server.getLocalPort() + probePath;
    }

    public int probeRequestCount() {
        return probeRequests.get();
    }

    public void enableRelay() {
        relayEnabled = true;
    }

    private void handle(Socket connection) {
        try (Socket socket = connection) {
            socket.setSoTimeout(15000);
            InputStream in = new BufferedInputStream(socket.getInputStream());
            OutputStream out = new BufferedOutputStream(socket.getOutputStream());
            String requestLine = line(in);
            String[] parts = requestLine.split(" ", 3);
            if (parts.length != 3 || !Arrays.asList("GET", "POST", "HEAD").contains(parts[0])) {
                reject(out, 405);
                return;
            }
            String method = parts[0];
            String target = parts[1];
            if (!target.startsWith("/") || target.startsWith("//") || target.contains("\\")
                || target.contains("#") || target.length() > 32768) {
                reject(out, 400);
                return;
            }
            Map<String, String> incoming = new TreeMap<>(String.CASE_INSENSITIVE_ORDER);
            int headerBytes = 0;
            for (int n = 0; ; n++) {
                String headerLine = line(in);
                headerBytes += headerLine.length();
                if (headerLine.isEmpty()) {
                    break;
                }
                if (n >= 100 || headerBytes > 65536) {
                    throw new IOException("Headers too large");
                }
                int colon = headerLine.indexOf(':');
                if (colon < 1) {
                    throw new IOException("Malformed header");
                }
                String name = headerLine.substring(0, colon);
                String value = headerLine.substring(colon + 1).trim();
                if (!name.matches("[A-Za-z0-9!#$%&'*+.^_`|~-]+")
                    || value.contains("\r") || value.contains("\n")) {
                    throw new IOException("Invalid header");
                }
                if (incoming.containsKey(name)) {
                    if (name.equalsIgnoreCase("Cookie")) {
                        incoming.put(name, incoming.get(name) + "; " + value);
                    } else {
                        throw new IOException("Duplicate header");
                    }
                } else {
                    incoming.put(name, value);
                }
            }
            // Once remote content is admitted, none of the preflight documents
            // may create a fresh browser realm with the control page's policy.
            if (relayEnabled && (target.equals(controlPath)
                || target.equals(policyPath) || target.equals(probePath))) {
                reject(out, 403);
                return;
            }
            // This single nonce route is deliberately anonymous: the native
            // preflight measures whether a cross-origin browser request reaches
            // it. It returns only a constant and can never contact the proxy.
            if (target.equals(probePath)) {
                if (!method.equals("GET")) {
                    reject(out, 405);
                    return;
                }
                String probeHost = "127.0.0.1:" + server.getLocalPort();
                if (!probeHost.equalsIgnoreCase(incoming.get("Host"))) {
                    reject(out, 403);
                    return;
                }
                probeRequests.incrementAndGet();
                writeProbeResponse(out);
                return;
            }
            String expectedHost = "localhost:" + server.getLocalPort();
            if (!expectedHost.equalsIgnoreCase(incoming.get("Host"))
                || !hasGate(incoming.get("Cookie"))) {
                reject(out, 403);
                listener.onEvent("Rejected unauthenticated local request");
                return;
            }
            String origin = incoming.get("Origin");
            if (origin != null && !localOrigin.equals(origin)) {
                reject(out, 403);
                listener.onEvent("Rejected foreign local origin");
                return;
            }
            // A service worker could synthesize documents without the enforced
            // connection policy. Verification needs dedicated workers only.
            if (incoming.containsKey("Service-Worker")) {
                reject(out, 403);
                return;
            }
            if (target.equals(controlPath) || target.equals(policyPath)) {
                if (!method.equals("GET")) {
                    reject(out, 405);
                    return;
                }
                writePreflightPage(out, target.equals(policyPath));
                return;
            }
            if (!relayEnabled) {
                reject(out, 403);
                return;
            }
            byte[] body = requestBody(in, incoming);
            if (!method.equals("POST") && body.length != 0) {
                reject(out, 400);
                return;
            }
            HttpUrl url = HttpUrl.get(base + target);
            if (!url.scheme().equals("http") || !url.host().equals(host) || url.port() != 80) {
                reject(out, 403);
                return;
            }
            Request.Builder upstream = new Request.Builder().url(url);
            Set<String> connectionHeaders = connectionTokens(incoming.get("Connection"));
            for (Map.Entry<String, String> header : incoming.entrySet()) {
                String name = header.getKey();
                String lowerName = name.toLowerCase(Locale.ROOT);
                if (HOP.contains(lowerName) || connectionHeaders.contains(lowerName)
                    || lowerName.equals("host") || lowerName.equals("content-length")
                    || lowerName.equals("cookie")) {
                    continue;
                }
                String value = header.getValue();
                if (lowerName.equals("origin")) {
                    value = base;
                }
                if (lowerName.equals("referer")) {
                    if (!value.startsWith(localOrigin + "/")) {
                        reject(out, 403);
                        return;
                    }
                    value = base + value.substring(localOrigin.length());
                }
                upstream.header(name, value);
            }
            CookieSelection selected = cookiesForRequest(url);
            String cookies = selected.header;
            if (!cookies.isEmpty()) {
                upstream.header("Cookie", cookies);
            }
            upstream.header("Accept-Encoding", "identity");
            if (incoming.get("User-Agent") == null) {
                reject(out, 400);
                return;
            }
            upstream.header("Host", host);
            upstream.method(method, method.equals("POST") ? RequestBody.create(body, null) : null);
            Request request = upstream.build();
            try (Response response = client.newCall(request).execute()) {
                byte[] responseBytes = response.body() == null
                    ? new byte[0]
                    : bounded(response.body().byteStream(), RESPONSE_LIMIT);
                saveCookies(url, response.headers());
                String type = response.header("Content-Type", "");
                boolean stats = url.encodedPath().equals("/api/v1/stats");
                listener.onEvent("HTTP " + response.code());
                if (stats && !cookies.isEmpty() && response.code() == 200
                    && type.toLowerCase(Locale.ROOT).contains("json")
                    && invidious(responseBytes, response.header("Content-Encoding", ""))) {
                    Map<String, String> captured = new LinkedHashMap<>();
                    for (String name : CAPTURE) {
                        String value = request.header(name);
                        if (value != null) {
                            captured.put(name, value);
                        }
                    }
                    // Only cookies actually sent in this successful request
                    // are verified. Its response may add or rotate cookies.
                    long expiresAt = selected.expiresAt;
                    if (expiresAt > System.currentTimeMillis()) {
                        listener.onVerified(Collections.unmodifiableMap(captured), expiresAt);
                    }
                }
                String location = response.header("Location");
                String mappedLocation = null;
                if (location != null) {
                    HttpUrl destination = url.resolve(location);
                    if (destination == null || !destination.scheme().equals("http")
                        || !destination.host().equals(host) || destination.port() != 80) {
                        reject(out, 502);
                        listener.onEvent("Blocked off-origin redirect");
                        return;
                    }
                    // Preserve the signed path/query bytes exactly; only the
                    // authority is mapped for an absolute/network-path URL.
                    if (location.startsWith(base + ":80")) {
                        mappedLocation = localOrigin + location.substring((base + ":80").length());
                    } else if (location.startsWith(base)) {
                        mappedLocation = localOrigin + location.substring(base.length());
                    } else if (location.startsWith("//" + host + ":80")) {
                        mappedLocation = localOrigin + location.substring(("//" + host + ":80").length());
                    } else if (location.startsWith("//" + host)) {
                        mappedLocation = localOrigin + location.substring(("//" + host).length());
                    } else if (location.startsWith("http://")) {
                        reject(out, 502);
                        return;
                    } else {
                        mappedLocation = location;
                    }
                }
                String reason = response.message().replaceAll("[^ -~]", "");
                out.write(("HTTP/1.1 " + response.code() + " "
                    + (reason.isEmpty() ? "Response" : reason) + "\r\n")
                    .getBytes(StandardCharsets.ISO_8859_1));
                Set<String> responseConnection = connectionTokens(response.header("Connection"));
                for (int i = 0; i < response.headers().size(); i++) {
                    String name = response.headers().name(i);
                    String value = response.headers().value(i);
                    String lowerName = name.toLowerCase(Locale.ROOT);
                    if (HOP.contains(lowerName) || responseConnection.contains(lowerName)
                        || lowerName.equals("content-length")) {
                        continue;
                    }
                    if (lowerName.equals("location")) {
                        value = mappedLocation;
                    }
                    // Upstream authentication cookies belong exclusively to
                    // this origin's native jar, never the shared localhost jar.
                    if (lowerName.equals("set-cookie") || lowerName.equals("cache-control")
                        || lowerName.equals("alt-svc")
                        || lowerName.equals("connection-allowlist")
                        || lowerName.equals("connection-allowlist-report-only")) {
                        continue;
                    }
                    if (lowerName.equals("access-control-allow-origin") && value.equals(base)) {
                        value = localOrigin;
                    }
                    out.write((name + ": " + value + "\r\n").getBytes(StandardCharsets.ISO_8859_1));
                }
                // This additional policy intersects the site's own CSP. It
                // leaves scripts/workers unchanged while preventing browser
                // side channels to another origin or another loopback port.
                out.write(("Content-Security-Policy: connect-src 'self'; form-action 'self'; "
                    + "frame-src 'none'; object-src 'none'; base-uri 'self'\r\n"
                    + "Connection-Allowlist: (response-origin); redirects=allow\r\n"
                    + "Content-Length: " + responseBytes.length
                    + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n")
                    .getBytes(StandardCharsets.ISO_8859_1));
                if (!method.equals("HEAD")) {
                    out.write(responseBytes);
                }
                out.flush();
            }
        } catch (Exception error) {
            listener.onEvent("Network request failed");
        }
    }

    private void writePreflightPage(OutputStream out, boolean enforcePolicy) throws IOException {
        byte[] body = "<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>"
            .getBytes(StandardCharsets.UTF_8);
        String policyHeader = enforcePolicy
            ? "Connection-Allowlist: (response-origin); redirects=allow\r\n"
            : "";
        out.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\n"
            + "Content-Security-Policy: connect-src 'self' http://127.0.0.1:"
            + server.getLocalPort()
            + "; form-action 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'\r\n"
            + policyHeader
            + "Content-Length: " + body.length + "\r\nConnection: close\r\n\r\n")
            .getBytes(StandardCharsets.ISO_8859_1));
        out.write(body);
        out.flush();
    }

    private static void writeProbeResponse(OutputStream out) throws IOException {
        out.write(("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
            + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n"
            + "Connection-Allowlist: (response-origin); redirects=allow\r\n"
            + "Content-Length: 2\r\nConnection: close\r\n\r\nok")
            .getBytes(StandardCharsets.ISO_8859_1));
        out.flush();
    }

    private boolean hasGate(String cookie) {
        if (cookie == null) {
            return false;
        }
        for (String part : cookie.split(";")) {
            int eq = part.indexOf('=');
            if (eq > 0 && part.substring(0, eq).trim().equals(GATE_COOKIE)) {
                return MessageDigest.isEqual(
                    gateToken.getBytes(StandardCharsets.US_ASCII),
                    part.substring(eq + 1).trim().getBytes(StandardCharsets.US_ASCII));
            }
        }
        return false;
    }

    synchronized void saveCookies(HttpUrl url, Headers headers) {
        for (Cookie cookie : Cookie.parseAll(url, headers)) {
            if (!cookie.domain().equals(host) || cookie.name().equals(GATE_COOKIE)) {
                continue;
            }
            String key = cookie.name() + "\n" + cookie.path();
            if (cookie.expiresAt() <= System.currentTimeMillis()) {
                jar.remove(key);
            } else {
                jar.put(key, cookie);
            }
        }
    }

    static final class CookieSelection {
        final String header;
        final long expiresAt;

        CookieSelection(String header, long expiresAt) {
            this.header = header;
            this.expiresAt = expiresAt;
        }
    }

    synchronized CookieSelection cookiesForRequest(HttpUrl url) {
        List<String> pairs = new ArrayList<>();
        long now = System.currentTimeMillis();
        long earliest = now + TimeUnit.DAYS.toMillis(7);
        boolean rootOnly = true;
        // Never forward browser cookies: old localhost cookies can belong to a
        // different instance. This run's native jar is the only upstream source.
        for (Iterator<Cookie> iterator = jar.values().iterator(); iterator.hasNext();) {
            Cookie cookie = iterator.next();
            if (cookie.expiresAt() <= now) {
                iterator.remove();
                continue;
            }
            String path = url.encodedPath();
            String cookiePath = cookie.path();
            if (path.equals(cookiePath)
                || path.startsWith(cookiePath.endsWith("/") ? cookiePath : cookiePath + "/")) {
                // Secure is retained on the cookie. The sole remote transport
                // is this exact cryptographic Tor onion over explicit SOCKS;
                // the jar is never used for clearnet HTTP or another host.
                pairs.add(cookie.name() + "=" + cookie.value());
                rootOnly &= cookie.path().equals("/");
                earliest = Math.min(earliest,
                    cookie.persistent() ? cookie.expiresAt() : now + TimeUnit.DAYS.toMillis(1));
            }
        }
        return new CookieSelection(String.join("; ", pairs), rootOnly && !pairs.isEmpty() ? earliest : 0);
    }

    private static Set<String> connectionTokens(String value) {
        Set<String> result = new HashSet<>();
        if (value != null) {
            for (String part : value.split(",")) {
                result.add(part.trim().toLowerCase(Locale.ROOT));
            }
        }
        return result;
    }

    private static byte[] requestBody(InputStream in, Map<String, String> headers) throws IOException {
        String length = headers.get("Content-Length");
        String transfer = headers.get("Transfer-Encoding");
        if (length != null && transfer != null) {
            throw new IOException("Ambiguous framing");
        }
        ByteArrayOutputStream body = new ByteArrayOutputStream();
        if (transfer != null) {
            if (!transfer.equalsIgnoreCase("chunked")) {
                throw new IOException("Unsupported transfer");
            }
            while (true) {
                int size = Integer.parseInt(line(in).split(";", 2)[0].trim(), 16);
                if (size < 0 || size > REQUEST_LIMIT - body.size()) {
                    throw new IOException("Body too large");
                }
                if (size == 0) {
                    for (int n = 0; ; n++) {
                        String trailer = line(in);
                        if (trailer.isEmpty()) {
                            break;
                        }
                        if (n >= 32) {
                            throw new IOException("Trailers too large");
                        }
                    }
                    break;
                }
                copyExactly(in, body, size);
                if (!line(in).isEmpty()) {
                    throw new IOException("Malformed chunk");
                }
            }
        } else if (length != null) {
            int size = Integer.parseInt(length);
            if (size < 0 || size > REQUEST_LIMIT) {
                throw new IOException("Body too large");
            }
            copyExactly(in, body, size);
        }
        return body.toByteArray();
    }

    private static void copyExactly(InputStream in, OutputStream out, int length) throws IOException {
        byte[] buffer = new byte[8192];
        while (length > 0) {
            int count = in.read(buffer, 0, Math.min(buffer.length, length));
            if (count < 0) {
                throw new EOFException();
            }
            out.write(buffer, 0, count);
            length -= count;
        }
    }

    private static String line(InputStream in) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        for (int character; (character = in.read()) >= 0;) {
            if (character == '\n') {
                byte[] buffer = bytes.toByteArray();
                int length = buffer.length;
                if (length > 0 && buffer[length - 1] == '\r') {
                    length--;
                }
                return new String(buffer, 0, length, StandardCharsets.ISO_8859_1);
            }
            if (bytes.size() >= 32768) {
                throw new IOException("Line too long");
            }
            bytes.write(character);
        }
        throw new EOFException();
    }

    private static byte[] bounded(InputStream in, int limit) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        for (int count; (count = in.read(buffer)) >= 0;) {
            if (count > limit - bytes.size()) {
                throw new IOException("Response too large");
            }
            bytes.write(buffer, 0, count);
        }
        return bytes.toByteArray();
    }

    private static boolean invidious(byte[] body, String encoding) {
        try {
            InputStream in = new ByteArrayInputStream(body);
            if (!encoding.isEmpty() && !encoding.equalsIgnoreCase("identity")) {
                return false;
            }
            JSONObject software = new JSONObject(
                new String(bounded(in, RESPONSE_LIMIT), StandardCharsets.UTF_8))
                .optJSONObject("software");
            return software != null && "invidious".equals(software.optString("name"));
        } catch (Exception ignored) {
            return false;
        }
    }

    private static void reject(OutputStream out, int code) throws IOException {
        out.write(("HTTP/1.1 " + code
            + " Rejected\r\nContent-Length: 0\r\nCache-Control: no-store\r\n"
            + "Connection-Allowlist: (response-origin); redirects=allow\r\n"
            + "Connection: close\r\n\r\n")
            .getBytes(StandardCharsets.ISO_8859_1));
        out.flush();
    }

    @Override
    public void close() {
        closed = true;
        try {
            if (server != null) {
                server.close();
            }
        } catch (IOException ignored) {
            // Continue closing active connections if the listener is already closed.
        }
        for (Socket connection : connections) {
            try {
                connection.close();
            } catch (IOException ignored) {
                // Other connections still need to be closed.
            }
        }
        client.dispatcher().cancelAll();
        client.connectionPool().evictAll();
        workers.shutdownNow();
        synchronized (this) {
            jar.clear();
        }
    }
}
