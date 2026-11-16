# NerdVPN browser sign-in verification

Work performed on 15 November 2026, continuing into 16 November UTC. This
record supplements the earlier [issue 38 investigation](issue-38-nerdvpn.md).

## Change and boundaries

Ordinary accounts on `https://invidious.nerdvpn.de` now offer an explicit
**Sign in with browser** choice when Videre's network proxy is off. Android
opens the configured default browser. **Sign in in app** enables JavaScript for
a temporary direct session at the canonical HTTPS NerdVPN origin. An immutable
origin restriction is installed in the browser proxy before scripts or page
loading start. HTTP(S) browser traffic to other hosts, schemes, or ports,
including redirects to those destinations, is rejected before outbound socket
allocation. Scripts are disabled again on exchange and cleanup.
Proxy/onion and persistent gateway sessions remain script-disabled; page scripts
can create WebRTC connections outside an HTTP proxy.

The external browser uses its own cookies and connection policy. Videre never
changes the app's proxy setting to launch it. This option does not apply to
onion addresses or persistent gateway-cookie sessions.

The native flow retains an in-memory S256 verifier and random callback nonce.
A callback-only Android activity returns to the existing app activity. The
callback is consumed before shared-link handling; cold, unrelated, repeated,
cancelled, or expired callbacks cannot create a login. Token exchange stays on
the selected origin without redirects. External-browser exchange imports no
browser cookies; in-app exchange uses only its temporary same-origin cookies,
which are cleared afterward. A separate
preflight fix prevents logout or a newer login from being followed by a stale
browser launch.

The protocol was checked against NerdVPN's published
[PKCE/API-key patch at commit 4286d62](https://git.nerdvpn.de/NerdVPN.de/invidious/src/commit/4286d62da5096c0a9527b831d40b6afa195e086d/patches/invidious/1001-api-key-retrieval.patch).
Its authorization codes are single-use and expire after 60 seconds; the native
exchange starts immediately when the callback arrives. Videre's entire pending
browser attempt has a separate ten-minute deadline.

## Automated checks

- Canonical pinned Flutter validation: 3,194 tests passed; six optional live
  tests skipped. Formatting passed. Strict analysis passed; the existing app
  analysis baseline remained four warnings and 236 informational diagnostics.
- Native JVM suites: 124 proxy tests and 32 application tests passed, including
  13 browser-attempt regressions and seven JavaScript-scope/route regressions.
- Five real-WebView privacy and temporary-profile cleanup tests passed on the
  persistent Android AVD in the isolated library test host.
- Release helper: 14 checks passed. APK signing verification: ten tests passed.
  Feedback service: 52 tests passed using Node 24.22.1 outside the workspace
  sandbox. Its junction/child-server fixtures failed in the sandbox; the
  unchanged suite passed with normal host access.
- Empty or malformed successful video metadata now produces an actionable
  service error without broadening retries or backend fallback. All 242 focused
  service, metadata-retry, and backend-fallback tests passed. The 13 new metadata
  cases failed before repair. A fixture was also corrected to compare the saved
  selected account before and after the request, including its `inUse` flag.
- The two stale-login preflight regressions failed before the service fix and
  passed afterward. Independent native callback/lifecycle review also caught
  and corrected the browser task-stack return path before device testing.

## Live account evidence

Used the persistent `Videre_NerdVPN_Test` Android 16 x86_64 AVD with
data-preserving APK updates. No account was removed or signed out.

Profile build `1.22.46+60918` SHA-256:
`a3f8c97a3e362dadf411c10346ff71e774587fd7a23dde541145a3cf8ec21a42`.
The current Dart compilation was explicitly verified after detecting a stale
incremental build.

- The explicit choice opened Android's default Chrome browser.
- Chrome already held the supplied NerdVPN account's session. A fresh Videre
  authorization grant was approved and returned to the original app activity.
- Videre showed the account as logged in with its API key available. The pending
  history-sync notice cleared.
- A first attempt expired while Chrome was unresponsive; the timeout preserved
  the prior login. A fresh attempt completed normally at the protocol level.
- After a data-preserving update and app restart, authenticated history and
  subscription requests returned HTTP 200 with the expected JSON shapes.
  These were real authenticated endpoints, not local-library fallbacks.

Internal API measurements used the same-source debug build because AOT profile
builds disable Dart expression evaluation. Debug APK SHA-256:
`b0f4482eb6d99269898e6dcf4c19cfa4baa5a4badb9c2b515fa85bf79ca6ea33`.
The native browser return itself was verified on the profile APK.

The external-browser test reused its existing authenticated session. A later
test of **Sign in in app** on the final debug build passed NerdVPN's JavaScript
challenge, reached the login form, submitted the supplied credentials, approved
the authorization form, and returned to Videre. Authenticated history and
subscription requests again returned HTTP 200. The in-app test therefore covers
a fresh password submission as well as the PKCE callback and temporary cleanup.
Credential values and authorization grants were not included in diagnostic
receipts. Task-local receipts are under the ignored `build/issue38-auth-browser/`
directory.

Final debug APK SHA-256:
`cbdbabf51f2fb6d4faf66137738f9a86e267517fb7e008d8889a07530c1b5a8d`.
Final optimized profile APK SHA-256:
`426cc07cc724ac56b7705e8499fe14794ec5141c82b1d76a39b46c6ceb6495e7`.
Both APKs were inspected for the new metadata error and scoped JavaScript code,
in addition to successful builds. The final debug app reports
`InvidiousServiceError` for the empty metadata response; valid video metadata
still loads through the production service.

The final read-only API sweep also passed fixture metadata, video search (20
results), Music song mapping (20), channel data (30 recent videos), comments
(20), public playlist search (18), public playlist contents (10), and
authenticated playlists (a valid empty list). These requests used the app's
request/auth transport, response handling, and production models. They establish
API compatibility, not every corresponding screen interaction. A preliminary
helper rejected a valid channel row mixed into playlist search; matching the
existing production parser resolved that diagnostic failure without an app edit.

## Extended Android acceptance

Android initially reported repeated focus-dispatch ANRs in both
Chrome and Videre on this AVD. The captured Videre main-thread stack was in the
normal message-queue wait, which does not establish an application deadlock.
The same emulator was rebooted without clearing its data before repeating the
affected checks. Authenticated account requests still succeeded afterward.

An independent read-only metadata probe received HTTP 200 with an empty body
for `jNQXAC9IVRw`; authenticated account endpoints succeeded. The app repair
improves its error reporting, not the availability of that remote video.

After reboot, `tV5UilNUYRY` passed DASH playback and forward/backward native seeks.
Progressive playback and both seeks also advanced normally, but its first
post-test shutdown exceeded the diagnostic ten-second budget. A cleanup retry
stopped playback and restored the local test records and preferences. That
entire progressive receipt remains marked incomplete rather than hiding the
timeout. A final-build repeat with the 214-second sample passed playback, both
seeks, Stop (4.5 seconds including the two-second write-drain wait), and local
history/preferences restoration together.

The production audio transport passed initial playback, screen-off advancement,
media-session Pause, and Resume. The test stopped normally and restored history
and preferences. This establishes native background transport, not every Music
search, artist, playlist, and queue interaction.

Initial download checks transferred bytes without authentication/storage errors
but exceeded their three-minute budget at the observed server throughput. Their
owned partial downloads were removed. The final build completed the 214-second
sample's MP4 download in approximately 216 seconds (7,823,496 bytes), within an
explicit ten-minute transfer budget. With Wi-Fi and mobile data disabled, the
native decoder reported a file source and advanced normally. Forward seeking to
12 seconds and backward seeking to two seconds both passed. Stop completed in
4.4 seconds, including the helper's two-second write-drain wait. The test removed
only its owned download and restored local history, preferences, and connectivity.
This final check did not restart the process while offline; the separate podcast
acceptance record covers offline resume across process restart.

The first task-local playback runner also had a snapshot-helper defect: dynamic
dispatch could not call Sembast's extension methods. Its restoration result is
not accepted as proof of restoring the test video's original local progress.
This helper is excluded from the APK. It was repaired to verify a typed snapshot
closure before any playback mutation. The new snapshot-only run and the later
DASH/audio runs verified restoration successfully. Helper expression comments
also required block syntax because the VM adapter joins expression lines.

No GitHub release has been published from these changes. Physical phone/TV,
ARM, and the full live Invidious integration suite remain unverified here.
