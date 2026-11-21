# NerdVPN sign-in investigation

[Issue #49](https://github.com/DVBeckwitt/Videre/issues/49) shows the HTTPS NerdVPN account settings in French with an English sign-in error. In the v1.22.51 source (`db2a8071`), that message comes from the exchange of an authorization code for a token. A rejected password, an expired code, and a browser that cannot start have different error paths.

## Reproducing the reported dialog

On November 21, 2026, three Flutter widget cases against the unmodified release exercised the protected sign-in method and the real French account error dialog. The native channel supplied a connection failure, HTTP 429, or HTTP 503. Each produced the reporter’s exact combination of **Erreur** and “The server could not complete sign-in. Try again later.” These cases establish how the app presented the failure. The report contains no HTTP status or transport diagnostic that identifies the original cause.

The patched Flutter tests exercise the account and add-server dialogs, transport error categories, a saved retry deadline, and preservation of existing credentials. English and French messages tell the user when to start a fresh sign-in.

## Reproducing an automatic second request

A loopback server replied to every token POST with HTTP 503 and `Retry-After: 0`. Using the release’s repeatable request body and OkHttp 4.12.0, a single exchange sent **two POSTs** despite connection retries being disabled. With the patched one-shot body the same exchange sent **one POST** and returned HTTP 503. The application JVM regression runs without contacting NerdVPN.

NerdVPN documents single-use authorization codes. An automatic second request can reuse an already-consumed code and obscure the first response. It does not account for the server’s initial 503. [NerdVPN PKCE implementation](https://git.nerdvpn.de/NerdVPN.de/invidious/src/commit/4286d62da5096c0a9527b831d40b6afa195e086d/patches/invidious/1001-api-key-retrieval.patch)

## Patched build checks

The pinned Flutter validation ran 4,547 offline tests with six optional live tests skipped. Formatting checked 859 files. Strict analysis passed, and the app-wide analyzer retained its 221 baseline diagnostics. All five validation-helper checks passed.

The Android app, proxy, and recommendation JVM suites passed 68, 157, and 72 tests respectively. The x86_64 Android profile APK contains 53 release notes, including a byte-for-byte copy of the installed version’s Markdown. Its SHA-256 is `ed77bbb7007c392ced36892669fe6a856e9bc4eff69c8a3f88b0019ce148382d`.
