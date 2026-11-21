# NerdVPN sign-in investigation

[Issue #49](https://github.com/DVBeckwitt/Videre/issues/49) shows the HTTPS NerdVPN account settings in French with an English sign-in error. In the v1.22.51 source (`db2a8071`), that message comes from the exchange of an authorization code for a token. A rejected password, an expired code, and a browser that cannot start have different error paths.

## Reproducing the reported dialog

On November 21, 2026, three Flutter widget cases against the unmodified release exercised the protected sign-in method and the real French account error dialog. The native channel supplied a connection failure, HTTP 429, or HTTP 503. Each produced the reporter’s exact combination of **Erreur** and “The server could not complete sign-in. Try again later.” These cases establish how the app presented the failure. The report contains no HTTP status or transport diagnostic that identifies the original cause.

The patched Flutter tests exercise the account and add-server dialogs, transport error categories, a saved retry deadline, and preservation of existing credentials. English and French messages tell the user when to start a fresh sign-in.

## Live Android reproduction attempt

On the persistent Android 16/API 36 x86_64 emulator, the installed stock v1.22.51+60956 APK was verified before testing. A separate Videre profile held the dedicated test account on `https://invidious.nerdvpn.de`. After network connectivity was verified, a fresh protected setup completed the official login and consent screens. Videre returned to Home. The account showed **Logged in** and **NerdVPN API access ready**.

The saved-account action from the report, **Settings → Manage servers → Sign in to protected server**, also completed a fresh login and consent and returned to the account with both statuses intact. Neither run showed the reported error or a cooldown. These successes establish that the released client could complete that path on this device and connection. The report’s original HTTP status and network conditions remain unknown.

The patched APK was installed over the stock build. A separate ordinary HTTPS account offered browser and in-app sign-in. **Sign in in app** completed a fresh login and consent on the official NerdVPN origin. The saved account displayed **Sign in to NerdVPN**, **Logged in**, and **NerdVPN API access ready**.

## Reproducing an automatic second request

A loopback server replied to every token POST with HTTP 503 and `Retry-After: 0`. Using the release’s repeatable request body and OkHttp 4.12.0, a single exchange sent **two POSTs** despite connection retries being disabled. With the patched one-shot body the same exchange sent **one POST** and returned HTTP 503. The application JVM regression runs without contacting NerdVPN.

NerdVPN documents single-use authorization codes. An automatic second request can reuse an already-consumed code and obscure the first response. It does not account for the server’s initial 503. [NerdVPN PKCE implementation](https://git.nerdvpn.de/NerdVPN.de/invidious/src/commit/4286d62da5096c0a9527b831d40b6afa195e086d/patches/invidious/1001-api-key-retrieval.patch)

## Patched build checks

The pinned Flutter validation ran 4,547 offline tests with six optional live tests skipped. Formatting checked 859 files. Strict analysis passed, and the app-wide analyzer retained its 221 baseline diagnostics. All five validation-helper checks passed.

The Android app, proxy, and recommendation JVM suites passed 68, 157, and 72 tests respectively. The x86_64 Android profile APK contains 53 release notes, including a byte-for-byte copy of the installed version’s Markdown. Its SHA-256 is `ed77bbb7007c392ced36892669fe6a856e9bc4eff69c8a3f88b0019ce148382d`.

In the emulator’s phone layout, the instance manager showed the optional-host explanation, custom-port example, and both documentation addresses. **Find media hosts** reported that the sample revealed no additional hosts. No approval was granted. The release notes reader opened the installed 1.22.51 notes and displayed the selected older 1.22.51 Beta 4 notes.

In the same emulator’s TV layout, D-pad focus reached **Settings → Release notes**. Center opened the reader, and the version picker switched to 1.22.51 Beta 4 using Center, Down, and Center.

## HTTPS and saved NerdVPN follow-up

The saved ordinary NerdVPN HTTPS account loaded public search results and played a video. Android reported **PLAYING** at 0 and 4,279 ms on the patched build above.

An older saved NerdVPN account could also fail its first **Find media hosts** check while Videre moved a legacy API-key header into secure storage. The follow-up regression test reproduced the cancellation and verified that the fixed check finishes the metadata and media probe after migration. A concurrent credential edit still cancels the check before either request. Phone and TV widget tests also verified that a generic protected HTTPS account retains its configured port and path and opens native sign-in without using NerdVPN API access.

Formatting and strict analysis passed on the follow-up. All 4,551 offline Flutter tests passed, with six optional live tests skipped. The follow-up Android profile APK SHA-256 is `494ec6c803c5fa96fd31ccfbef7c902bd9b1ca2b1203f61d6e9abe9765b11467`. After updating, the saved NerdVPN account remained logged in and the media-host sample check completed without finding an additional host.

On that final APK, a credential-free account at `https://invidious.dvbeckwitt.duckdns.org` returned live search and watch metadata. Android playback advanced from 5,524 to 12,673 ms. A separate instance at `https://eu.yt.chocolatemoo53.com` also returned search and watch results, and the sample discovered two companion addresses. Videre blocked a playback route outside the account’s approved origins. The discovery dialog was canceled without approving new hosts.

The isolated Android instrumentation package passed 19 gateway-cookie, WebView and media privacy, NerdVPN transport, and HTTPS companion tests. Two session restart tests also passed in separate seed and check processes. The HTTPS companion fixture decoded an approved stream without forwarding the instance’s credentials, and the unapproved host received no connection. Generic protected HTTPS coverage used the emulator fixtures and the phone/TV widgets.

The final APK also played a video through the saved NerdVPN HTTPS account. The watch metadata loaded and the native playback position advanced from 12,489 to 17,203 ms.
