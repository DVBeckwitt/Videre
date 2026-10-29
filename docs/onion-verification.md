# Onion instance verification

Some onion instances use Gandalf to verify browser requests before allowing the
Invidious API. With SOCKS5 enabled, Videre detects a Gandalf response to an API
read, opens its verification screen, then retries the read once with the verified
session. The screen uses the Android system WebView; it does not bundle Gecko or
require an external browser. Ordinary instance errors do not trigger verification.

The verification screen exposes an authenticated localhost origin to WebView so
the challenge has access to Web Crypto. A short-lived native gateway forwards
requests to one HTTP v3 onion origin on port 80 through the saved SOCKS5 endpoint.
It does not provide a general proxy. The upstream challenge runs normally; its
HTML, JavaScript and signed query values are not patched to bypass verification.

## Session protection

- The gateway binds to loopback on an ephemeral port and requires a random,
  HttpOnly gate cookie. Host and Origin checks reject other local callers.
- Remote requests use SOCKS5 with proxy-side onion resolution and no direct
  fallback. Redirects and browser resources are restricted to the selected origin.
- Every proxied document uses a browser-enforced `Connection-Allowlist` for the
  local gateway, with WebRTC blocked. Before loading any upstream page, trusted
  local pages check that the provider enforces both HTTP and WebRTC restrictions.
  Verification stops if either check fails. HTTP proxy settings and CSP alone do
  not cover every browser network API.
- Upstream cookies stay in the native, origin-specific jar instead of the
  localhost browser cookie store. Only root-path cookies actually sent with a
  successful Invidious statistics request are exported to the app. Response
  cookies newly added after that request are not treated as verified credentials.
- A session contains only the verified Cookie, User-Agent, Accept,
  Accept-Language and Accept-Encoding fields. The gateway uses `identity`
  encoding from the first request so Dart and Android media transports reproduce
  the same fingerprint. Native media requests normalize duplicate fingerprint
  headers before sending them.
- Saved sessions use AES-GCM with a device-local Android Keystore key, atomic
  writes and private, backup-excluded storage. Browser profile data is excluded
  from Android cloud backup and device transfer. Sessions never become server
  custom headers or part of a Videre export.
- The app matches scheme, hostname and port before applying a session. API,
  thumbnail, download and native media redirect paths prevent forwarding session
  headers to another origin. Media segments are scoped to the original source.
- Sessions are bound to the saved SOCKS5 configuration and their cookie expiry.
  Proxy changes invalidate in-flight results. An account SID takes precedence
  over a verification cookie with the same name.
- Diagnostics contain status and operation categories, never session values,
  gate tokens or signed challenge query strings.

## Lifecycle

Only a foreground Android activity may open verification. Concurrent failures
share one attempt, which can be cancelled and has a bounded lifetime. A read is
retried once after verification; writes are not automatically replayed. Background
jobs reuse a saved session and do not open a verification screen.

Expired or rejected sessions can be renewed on a later foreground API read. The
instance controls its challenge and cookie lifetime. Disabling the configured
proxy disables use of the saved verification session.

The verification activity runs in a separate app process. Android 9 and later use
a dedicated WebView data-directory suffix. The provider version is checked before
creating the verification WebView. Unsupported providers and provider startup
failures leave the original request failed rather than changing network routing.

The connection restriction requires WebView based on Chromium 152 or later, plus
successful runtime enforcement checks. An unsupported provider produces a message
to update Android System WebView. See the [Chromium connection allowlist
documentation](https://developer.chrome.com/blog/connection-allowlist-announcement).
