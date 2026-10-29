package com.github.dvbeckwitt.videre.proxy;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.GeolocationPermissions;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.PermissionRequest;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ServiceWorkerClient;
import android.webkit.ServiceWorkerController;
import android.webkit.SslErrorHandler;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.webkit.ProxyConfig;
import androidx.webkit.ProxyController;
import androidx.webkit.WebViewFeature;
import androidx.webkit.WebViewCompat;
import java.io.ByteArrayInputStream;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** A short-lived browser check, isolated from the application's main process. */
public final class OnionVerificationActivity extends Activity implements OnionVerificationGateway.Listener {
    public static final String ORIGIN = "origin";
    public static final String ERROR = "error";
    public static final String PROXY_CONFIGURATION = "proxyConfiguration";
    private static final long TIMEOUT_MILLIS = 120_000;
    private static final String UNSUPPORTED_WEBVIEW = "ONION_VERIFICATION_UNSUPPORTED_WEBVIEW";
    private static final String TAG = "OnionVerification";
    private static boolean profileInitialized;
    private static int activeActivities;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService storage = Executors.newSingleThreadExecutor();
    private OnionVerificationGateway gateway;
    private WebView web;
    private String origin;
    private volatile String localOrigin;
    private ProxyPolicy policy;
    private volatile boolean closed;
    private boolean completing;
    private boolean secure;
    private boolean subtle;
    private boolean clicked;
    private volatile int preflightStage;
    private boolean preflightRunning;
    private int initialProbeCount;
    private Map<String, String> verifiedHeaders;
    private long verifiedExpiry;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        activeActivities++;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
        setResult(RESULT_CANCELED, new Intent().putExtra(ERROR, "ONION_VERIFICATION_CANCELLED"));
        handler.postDelayed(() -> fail("ONION_VERIFICATION_FAILED"), TIMEOUT_MILLIS);
        try {
            origin = getIntent().getStringExtra(ORIGIN);
            if (origin == null || !origin.equals(OnionSessionStoreKt.canonicalOnionOrigin(origin))) {
                fail("ONION_VERIFICATION_UNAVAILABLE");
                return;
            }
            policy = readPolicy(this);
            String expected = getIntent().getStringExtra(PROXY_CONFIGURATION);
            if (!policy.getEnabled() || expected == null || !policy.equals(parsePolicy(expected))) {
                fail("ONION_VERIFICATION_UNAVAILABLE");
                return;
            }
            // On API 24–27 this dedicated process is the application's sole
            // WebView user. Newer Android versions also isolate its profile.
            if (!profileInitialized) {
                if (Build.VERSION.SDK_INT >= 28) {
                    WebView.setDataDirectorySuffix("videre_verification");
                }
                profileInitialized = true;
            }
            if (!supportedProvider()) {
                fail(UNSUPPORTED_WEBVIEW);
                return;
            }
            createBrowser();
            byte[] random = new byte[24];
            new SecureRandom().nextBytes(random);
            String gate = android.util.Base64.encodeToString(random, android.util.Base64.NO_WRAP |
                android.util.Base64.URL_SAFE | android.util.Base64.NO_PADDING);
            gateway = new OnionVerificationGateway(origin, policy, gate, this);
            localOrigin = "http://localhost:" + gateway.start();
            CookieManager cookies = CookieManager.getInstance();
            cookies.setAcceptCookie(true);
            cookies.setAcceptThirdPartyCookies(web, false);
            // Never clear cookies belonging to another WebView or origin.
            cookies.setCookie(localOrigin, OnionVerificationGateway.GATE_COOKIE + "=" + gate +
                "; Path=/; HttpOnly; SameSite=Strict", accepted -> {
                    if (closed) {
                        return;
                    }
                    if (!accepted) {
                        fail("ONION_VERIFICATION_FAILED");
                        return;
                    }
                    configureProxy();
                });
        } catch (Exception | LinkageError error) {
            fail("ONION_VERIFICATION_UNAVAILABLE");
        }
    }

    private boolean supportedProvider() {
        try {
            PackageInfo provider = WebViewCompat.getCurrentWebViewPackage(this);
            return provider != null && provider.versionName != null &&
                Integer.parseInt(provider.versionName.split("\\.")[0]) >= 152;
        } catch (RuntimeException error) {
            return false;
        }
    }

    static ProxyPolicy readPolicy(Context context) throws JSONException {
        String saved = context.getSharedPreferences("videre_network_proxy", Context.MODE_PRIVATE)
            .getString("configuration", null);
        if (saved == null) {
            throw new IllegalStateException("SOCKS5 is required");
        }
        return parsePolicy(saved);
    }

    private static ProxyPolicy parsePolicy(String saved) throws JSONException {
        JSONObject json = new JSONObject(saved);
        Map<String, Object> values = new HashMap<>();
        for (Iterator<String> keys = json.keys(); keys.hasNext();) {
            String key = keys.next();
            values.put(key, json.get(key));
        }
        return ProxyPolicy.Companion.fromMap(values);
    }

    private void createBrowser() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setFitsSystemWindows(true);
        int pad = (int) (16 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);
        TextView title = new TextView(this);
        title.setText(R.string.onion_verification_title);
        title.setTextSize(20);
        root.addView(title);
        TextView status = new TextView(this);
        status.setText(R.string.onion_verification_progress);
        status.setPadding(0, pad / 2, 0, pad / 2);
        root.addView(status);
        Button cancel = new Button(this);
        cancel.setText(android.R.string.cancel);
        cancel.setOnClickListener(view -> fail("ONION_VERIFICATION_CANCELLED"));
        root.addView(cancel);
        web = new WebView(this);
        root.addView(web, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(root);
        WebView.setWebContentsDebuggingEnabled(false);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setCacheMode(WebSettings.LOAD_NO_CACHE);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setSupportMultipleWindows(false);
        if (Build.VERSION.SDK_INT >= 26) {
            settings.setSafeBrowsingEnabled(true);
        }
        web.setDownloadListener((url, ua, contentDisposition, mime, length) -> {});
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage message) {
                return true;
            }
            @Override
            public void onPermissionRequest(PermissionRequest request) {
                request.deny();
            }
            @Override
            public void onGeolocationPermissionsShowPrompt(String target, GeolocationPermissions.Callback callback) {
                callback.invoke(target, false, false);
            }
            @Override
            public boolean onJsAlert(WebView view, String url, String message, JsResult result) {
                result.cancel();
                return true;
            }
            @Override
            public boolean onJsConfirm(WebView view, String url, String message, JsResult result) {
                result.cancel();
                return true;
            }
            @Override
            public boolean onJsPrompt(WebView view, String url, String message, String value, JsPromptResult result) {
                result.cancel();
                return true;
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri target = request.getUrl();
                if (request.isForMainFrame() && isOnion(target)) {
                    String path = target.getEncodedPath();
                    String mapped = localOrigin + (path == null || path.isEmpty() ? "/" : path);
                    if (target.getEncodedQuery() != null) {
                        mapped += "?" + target.getEncodedQuery();
                    }
                    if (target.getEncodedFragment() != null) {
                        mapped += "#" + target.getEncodedFragment();
                    }
                    view.loadUrl(mapped);
                    return true;
                }
                return !isLocal(target);
            }
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return allowedResource(request.getUrl()) ? null : blocked();
            }
            @Override
            public void onPageFinished(WebView view, String url) {
                if (preflightStage > 0) {
                    startPreflight(url);
                } else {
                    inspect();
                }
            }
            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    fail("ONION_VERIFICATION_FAILED");
                }
            }
            @Override
            public void onReceivedSslError(WebView view, SslErrorHandler handle, SslError error) {
                handle.cancel();
            }
            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                fail("ONION_VERIFICATION_FAILED");
                return true;
            }
        });
        ServiceWorkerController workers = ServiceWorkerController.getInstance();
        workers.getServiceWorkerWebSettings().setAllowFileAccess(false);
        workers.getServiceWorkerWebSettings().setAllowContentAccess(false);
        workers.getServiceWorkerWebSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
        workers.getServiceWorkerWebSettings().setBlockNetworkLoads(true);
        workers.setServiceWorkerClient(new ServiceWorkerClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebResourceRequest request) {
                return blocked();
            }
        });
    }

    private void configureProxy() {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) {
            fail(UNSUPPORTED_WEBVIEW);
            return;
        }
        try {
            String proxy = "http://127.0.0.1:" + Uri.parse(localOrigin).getPort();
            ProxyConfig config = new ProxyConfig.Builder().addProxyRule(proxy).build();
            // Loopback uses the authenticated gateway. Everything else reaches
            // the same socket as an HTTP proxy request or CONNECT, both rejected
            // before egress. Only the native fixed-origin relay can contact Tor.
            ProxyController.getInstance().setProxyOverride(config, this::runOnUiThread, () -> {
                if (closed) {
                    return;
                }
                preflightStage = 1;
                web.loadUrl(gateway.controlUrl());
                handler.postDelayed(poll, 500);
            });
        } catch (Exception error) {
            fail("ONION_VERIFICATION_UNAVAILABLE");
        }
    }

    private boolean isOnion(Uri uri) {
        Uri target = Uri.parse(origin);
        return "http".equals(uri.getScheme()) && target.getHost().equals(uri.getHost()) &&
            (uri.getPort() == -1 || uri.getPort() == 80) && uri.getUserInfo() == null;
    }

    private boolean isLocal(Uri uri) {
        if (uri == null || localOrigin == null) {
            return false;
        }
        return "http".equals(uri.getScheme()) && "localhost".equals(uri.getHost()) &&
            uri.getPort() == Uri.parse(localOrigin).getPort() && uri.getUserInfo() == null;
    }

    private boolean allowedResource(Uri uri) {
        if (closed || uri == null) {
            return false;
        }
        boolean preflightProbe = preflightStage > 0 && gateway != null &&
            uri.toString().equals(gateway.probeUrl());
        return preflightProbe || isLocal(uri) || "data".equals(uri.getScheme()) ||
            (localOrigin != null && uri.toString().startsWith("blob:" + localOrigin + "/"));
    }

    private static WebResourceResponse blocked() {
        return new WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden",
            Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
    }

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            if (!closed) {
                if (preflightStage > 0) {
                    inspectPreflight();
                } else {
                    inspect();
                }
                handler.postDelayed(this, 500);
            }
        }
    };

    private void startPreflight(String url) {
        String expected = preflightStage == 1 ? gateway.controlUrl() : gateway.policyUrl();
        if (closed || preflightRunning || !expected.equals(url)) {
            return;
        }
        preflightRunning = true;
        initialProbeCount = gateway.probeRequestCount();
        // These pages are generated locally, before the relay is enabled. The
        // only fetch target is the same loopback listener through its other
        // hostname. Constructing and closing a peer connection without an SDP
        // offer, data channel or candidate pool does not start ICE gathering.
        String script = "window.__viderePreflight=null;(async function(){try{" +
            "var pc=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:9'}],iceCandidatePoolSize:0});" +
            "var servers=pc.getConfiguration().iceServers.length;pc.close();var fetched=false;" +
            "try{var response=await fetch(" + JSONObject.quote(gateway.probeUrl()) +
            ",{cache:'no-store',credentials:'omit'});fetched=response.status===200&&(await response.text())==='ok';}catch(e){}" +
            "window.__viderePreflight=JSON.stringify({servers:servers,fetched:fetched});" +
            "}catch(e){window.__viderePreflight=JSON.stringify({failed:true});}})();";
        web.evaluateJavascript(script, ignored -> {});
    }

    private void inspectPreflight() {
        if (!preflightRunning || closed) {
            return;
        }
        final int stage = preflightStage;
        web.evaluateJavascript("window.__viderePreflight||null", value -> {
            if (closed || !preflightRunning || preflightStage != stage || "null".equals(value)) {
                return;
            }
            try {
                JSONObject result = new JSONObject(new JSONArray("[" + value + "]").getString(0));
                int count = gateway.probeRequestCount();
                if (result.optBoolean("failed")) {
                    fail(UNSUPPORTED_WEBVIEW);
                } else if (preflightStage == 1 && result.getBoolean("fetched") &&
                    result.getInt("servers") == 1 && count == initialProbeCount + 1) {
                    Log.i(TAG, "Local browser policy control passed");
                    preflightStage = 2;
                    preflightRunning = false;
                    web.loadUrl(gateway.policyUrl());
                } else if (preflightStage == 2 && !result.getBoolean("fetched") &&
                    result.getInt("servers") == 0 && count == initialProbeCount) {
                    Log.i(TAG, "Browser connection and WebRTC restrictions verified");
                    preflightRunning = false;
                    preflightStage = 0;
                    // Remove the unprotected control document from history
                    // before any remote script can execute in this WebView.
                    web.clearHistory();
                    gateway.enableRelay();
                    web.loadUrl(localOrigin + "/api/v1/stats");
                } else {
                    Log.w(TAG, "Local browser policy check failed at stage " + preflightStage);
                    fail(UNSUPPORTED_WEBVIEW);
                }
            } catch (Exception error) {
                fail(UNSUPPORTED_WEBVIEW);
            }
        });
    }

    private void inspect() {
        if (closed || web == null || web.getUrl() == null || !isLocal(Uri.parse(web.getUrl()))) {
            return;
        }
        // This invokes the normal widget interaction once. The page and its
        // proof-of-work implementation run unchanged in a real secure context.
        String script = "(function(){var clicked=false;" + (clicked ? "" :
            "var w=document.querySelector('altcha-widget');var r=w&&(w.shadowRoot||w);" +
            "var c=r&&r.querySelector('input[type=checkbox]');if(c&&!c.disabled&&!c.checked){c.click();clicked=true;}") +
            "return JSON.stringify({secure:globalThis.isSecureContext===true," +
            "subtle:!!(globalThis.crypto&&globalThis.crypto.subtle),clicked:clicked});})()";
        web.evaluateJavascript(script, value -> {
            if (closed) {
                return;
            }
            try {
                JSONObject result = new JSONObject(new JSONArray("[" + value + "]").getString(0));
                secure = result.getBoolean("secure");
                subtle = result.getBoolean("subtle");
                clicked |= result.optBoolean("clicked");
                completeIfReady();
            } catch (Exception ignored) {
                // A navigation can replace this JavaScript context.
            }
        });
    }

    @Override
    public void onEvent(String safe) {
        // Do not persist browser activity or session material.
    }

    @Override
    public void onVerified(Map<String, String> headers, long expiresAt) {
        runOnUiThread(() -> {
            if (closed || completing) {
                return;
            }
            verifiedHeaders = new LinkedHashMap<>(headers);
            verifiedExpiry = expiresAt;
            completeIfReady();
        });
    }

    private void completeIfReady() {
        if (closed || completing || !secure || !subtle || verifiedHeaders == null) {
            return;
        }
        completing = true;
        storage.execute(() -> {
            try {
                if (!policy.equals(readPolicy(this))) {
                    throw new IllegalStateException("Proxy changed");
                }
                OnionSessionStore.save(this, origin, verifiedHeaders, verifiedExpiry, policy);
                runOnUiThread(() -> {
                    if (closed) {
                        return;
                    }
                    setResult(RESULT_OK, new Intent().putExtra(ORIGIN, origin));
                    finish();
                });
            } catch (Exception error) {
                runOnUiThread(() -> fail("ONION_VERIFICATION_FAILED"));
            }
        });
    }

    private void fail(String code) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            runOnUiThread(() -> fail(code));
            return;
        }
        if (closed || isFinishing()) {
            return;
        }
        setResult(RESULT_CANCELED, new Intent().putExtra(ERROR, code));
        finish();
    }

    @Override
    public void onBackPressed() {
        fail("ONION_VERIFICATION_CANCELLED");
    }

    @Override
    protected void onDestroy() {
        closed = true;
        handler.removeCallbacksAndMessages(null);
        storage.shutdownNow();
        if (gateway != null) {
            gateway.close();
        }
        if (web != null) {
            web.stopLoading();
            web.destroy();
        }
        if (localOrigin != null) {
            CookieManager.getInstance().setCookie(localOrigin, OnionVerificationGateway.GATE_COOKIE +
                "=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict", ignored -> CookieManager.getInstance().flush());
        }
        verifiedHeaders = null;
        super.onDestroy();
        activeActivities--;
        // The Activity owns this named process. Releasing it also discards the
        // native cookie jar, renderer and temporary proxy override together.
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            if (activeActivities == 0) {
                android.os.Process.killProcess(android.os.Process.myPid());
            }
        }, 750);
    }
}
