# NerdVPN privacy and persistent testing environment

Checked on 10 November 2026 in the existing local working tree. This extends the
issue 27–29 and regression-review evidence; it does not replace their records.

## App-owned YouTube requests

Production Music uses the selected Invidious instance. No production Music
client calls `music.youtube.com/youtubei/v1/`; the historical direct client is
test-only. Incoming YouTube links are identifiers for local routes, and sharing
a URL does not fetch that URL.

Dart and native HTTP/media guards reject official YouTube destinations before
connecting, including through SOCKS and redirects. New regressions explicitly
exercise a POST to `https://music.youtube.com/youtubei/v1/search`.
Shared Google API paths also reject percent-encoded separators, such as
`/youtube%2fv3/search`, while unrelated API paths remain unaffected.

The audit found that the embedded gateway-sign-in and backend-selection
browsers used a separate network stack. Both now require a process-local
filtering HTTP/CONNECT proxy before loading a page, even with the optional
SOCKS setting disabled. Official hosts are denied before DNS/socket creation.
Browser tunnels conservatively deny shared Google API hosts too, since their
encrypted paths cannot be inspected. Request framing and resource use are
bounded, SOCKS has no direct fallback, and closing a browser revokes its sockets
while leaving the denying proxy installed. Service-worker network access is
disabled for default and isolated profiles. Unsupported protection fails closed
with guidance to update Android System WebView.

This covers Videre-owned HTTP(S), including embedded browser resources. An
explicit action in a separate OS browser uses that browser's networking. The
selected Invidious operator still fetches YouTube upstream. See Android's
[WebView proxy contract](https://developer.android.com/reference/androidx/webkit/ProxyController)
and [service-worker network control](https://developer.android.com/reference/android/webkit/ServiceWorkerWebSettings).

## Saved login and default environment

The existing signed-in virtual device was stopped gracefully and copied to
`%LOCALAPPDATA%/Videre/testing/avd-home/Videre_NerdVPN_Test.avd`. The original
remains available for recovery. SHA-256 comparisons matched all six userdata,
encryption-key and cache base/overlay files before the copy was first booted.
The destination has an ACL limited to the current Windows user, SYSTEM and
administrators. No passwords or tokens were printed, exported to scripts, or
added to Git.

The launcher is `pwsh -NoProfile -File ./tools/start_test_emulator.ps1`.
It reuses `emulator-5596`, verifies AVD identity, refuses a conflicting port,
and never creates/wipes/resets the device or uninstalls the app. Optional
`-ApkPath` uses only `adb install -r`. Both a real cold boot and a second launcher
invocation that reused the running device succeeded. README and AGENTS establish
this as the Windows native acceptance default; offline CI needs no account.

After the move and cold boot, the actual app retained NerdVPN as its selected
account. Authenticated history and subscriptions returned HTTP 200; trending
and a fresh Music search also returned 200, without a new sign-in. Evidence is
under `build/nerdvpn-persistence-acceptance/`.

Login data remains in the virtual Android device. Native API/recovery secrets
use Android Keystore encryption; the existing account DB also contains a bearer
token, so this is not a claim that every copy is encrypted. Normal restarts and
compatible app updates preserve data. Server-side expiry or revocation can
still require authentication. Android documents the
[persistent userdata partition and reset flags](https://developer.android.com/studio/run/emulator-commandline).

Interrupted protected reauthentication previously left a pending flag that
blocked the last completed session after process death. Startup now reconciles
that abandoned attempt once, preserves expiry/revocation rules and rejects stale
callbacks. First-time incomplete sign-in still fails closed. Device tests also
exposed a Chromium missing-profile cleanup failure; absent profiles are now
treated as already cleared without recreating them.

## Evidence

- Canonical formatting, configured analysis and offline tests passed:
  **2,300 passed, four opt-in live skips**. The configured analyzer allows
  existing nonfatal warnings; this is not a warning-free claim.
- Native JVM suite: **93 passed**. Launcher safety fixtures: **11 passed**.
  Validation-helper tests: **5 passed**.
- Windows release-helper safety fixtures: **14 passed**. APK signing identity
  fixtures: **10 passed**. No signing material or release was produced.
- Actual Chromium: **two tests passed**, including the exact Music POST,
  embedded iframe/image, a redirect from a local fixture, teardown denial, and
  isolated-profile reopening. No official endpoint was contacted by the tests.
- Native session, encrypted-storage and recovery transport: **13 tests passed**.
  Two separate-process restart tests passed both their seed and check phases.
  These run in `com.github.dvbeckwitt.videre.proxy.test`, separate from the real
  app and its saved NerdVPN account.
- Focused Music adapter/SOCKS/UI tests and player/download/service suites also
  passed. They cover signed routes, original account ownership, bounded source
  fallback, captions, queue/playlist state, artwork, offline metadata and imports.

Supported Music browsing is standard Invidious search, channels, playlists and
trending. YouTube Music-only album, releases, charts and mood catalogs remain
unavailable and their feeds are hidden. A working upstream server cannot be
guaranteed for every video.

## Live NerdVPN acceptance

The persistent Android 16/API 36 x86_64 device used the saved account on
`invidious.nerdvpn.de`. Core acceptance ran on APK `64ad08ca…`; only the encoded
Google API path guard, Retry position and mini-player layout changed afterward.
The full receipt and screenshots are in `build/nerdvpn-full-acceptance/`.

| Flow | Observed result |
| --- | --- |
| Video | Search, details, decoded playback and seeking to 05:53 passed. |
| Captions | Manual and auto-generated English captions rendered. |
| Display and controls | Fit/Crop changed the same paused frame; Fit restored. Backend label disappeared with idle controls. |
| Music | Songs, channels and playlists returned results; artist and playlist details opened; Play all and Next worked. |
| Background audio | Playback advanced from 00:27 to 01:09 with Android Home in front; media notification Pause stopped playback. |
| Download | A new 3,990,497-byte audio WebM completed. Opening it from Downloads advanced from 00:08 to 00:28; the app's open file descriptor confirmed playback from that local file. |
| Cleanup | Only that newly created download was deleted. Downloads returned to their original empty state; no bookmarks or playlists were created. |
| TV layout | At 720 × 360 logical pixels, focused Korean titles and Watch Later details fit; D-pad navigation worked. This was forced-TV mode on an emulator. |

One initial Music metadata request returned HTTP 500 from NerdVPN. Visible Retry
received HTTP 200 and playback recovered, but exposed an app bug: the new song
inherited the previous video's 04:13 position. The failure branch now retains
the requested new-song position; deterministic tests cover both zero and an
explicit 37-second resume after a metadata failure. No upstream retry loop was
added. A separate one-pixel collapsed Music-player overflow with Korean text
was reproduced and corrected while retaining control and progress sizes.

The final APK, `app-debug-nerdvpn-complete.apk`, was installed through the
default launcher and retained the selected, logged-in NerdVPN account.
Authenticated history and subscriptions requests also returned HTTP 200. A fresh
Songs-row selection started at 00:00 and advanced to 00:09 despite nonzero
positions in the preceding sessions. The same Korean-title collapsed player
fit at the original phone dimensions with controls and progress visible and
no overflow. No HTTP 500 occurred in this final check; failure-and-Retry
position correctness remains covered by the deterministic regression above.
The installed APK hash independently matched the final artifact. The receipt is
`native-final-targeted-acceptance.json`; `final-restored-home.png` records the
restored idle Music Home after acceptance.

Final debug SHA-256:
`686b95795df29579ca3a41341f546751bc907bc9a97fb94f2b3d5b14801a36d7`.
Its packaged Dart kernel matches the forced fresh compilation, and native
privacy/session-cleanup symbols are present. All three profile APKs
(`armeabi-v7a`, `arm64-v8a`, `x86_64`) built after the final source changes.
Fresh compiled libraries matched merged outputs, stripping preserved ELF build
IDs, and APK libraries matched the stripped outputs. Receipts are
`build-identity-complete.json` and `profile-build-identity-complete.json` in the
acceptance directory. These profile artifacts were built, not separately
installed for runtime acceptance.

The live backend browser fallback was not opened: the saved NerdVPN selector
was already working, and the fallback appears only after discovery failure.
Actual Chromium default/isolated/redirect protection was covered by the local
instrumentation fixtures described above. Whitelisted Service logs showed
NerdVPN, SponsorBlock and Return YouTube Dislike hosts; those logs alone are
not exhaustive proof of all native media traffic.

Phone dimensions (540 × 1080, 240 dpi), Fit, Force TV off, the saved login,
network settings and backend selection were preserved. The device was restored
to NerdVPN Music Home with playback closed.

No commit, push or release was made. Windows/emulator checks do not establish
Linux hosted CI, physical-TV or the full Nix live-service-suite coverage.

## Tor and onion follow-up

The HTTP, native media/API, and embedded sign-in transports require SOCKS for
HTTP and HTTPS onion destinations, including redirects. The previous transport
guard covered only official NerdVPN HTTP. The expanded regression reproduced
an HTTPS onion reaching the Dart connection factory before the fix. Native
tests assert denial before the system proxy selector sees the destination.
Managed onion setup checks SOCKS before saving an API key. Onion browser links
target the installed Tor Browser, with a copyable address if it cannot open
the link directly. Clearnet and onion accounts keep separate credentials.

Invidious builds `/vi/` thumbnail URLs from its configured host. For the
recognized NerdVPN origins, Videre keeps these thumbnails on the selected
onion endpoint and retains their original query. The regression checks
account header scoping and rejects other hosts, ports, credentials and
traversal from the rewrite. See the [upstream thumbnail builder](https://github.com/iv-org/invidious/blob/master/src/invidious/videos/videos.cr#L352).

A temporary loopback-only Tor 0.4.9.15 client bootstrapped successfully.
The independent Tor check returned HTTP 200 with `IsTor=true`. Anonymous
requests to the official NerdVPN HTTP and HTTPS onion ports each timed out at
15 seconds before HTTP, so this run could not verify live onion authentication
or playback. The temporary process was stopped. Automatic approval review
blocked recursive deletion, so its temporary data directory was retained.
The saved NerdVPN account and its proxy settings were preserved.

On the persistent Android emulator, seven fixture tests passed and two optional
live-Orbot tests skipped in the separate `com.github.dvbeckwitt.videre.proxy.test`
package. These covered SOCKS destination hostnames, audio and video playback and
seeking, DASH/HLS, proxy failure and policy changes, and the embedded WebView
privacy boundary. Logs and probe receipts are under `build/tor-live-review/`.

Final canonical validation passed with **2,316 offline tests** and four opt-in
live skips. Formatting and configured analysis passed with the same nonfatal
diagnostics as the preceding build. The native JVM suite passed all **93 tests**.
The final x86_64 debug artifact is `app-debug-tor-reviewed.apk`, SHA-256
`694e0c4dc83705e7535595a78a2a2730ad01c50461b54d522e20e0f224d372d8`.
Its packaged Dart kernel matches the fresh compile. The APK contains both
YouTube guards, the WebView filter, the onion route guard and Tor Browser
handoff. See `final-debug-identity.json` in the same evidence directory.
Profile APKs built for `armeabi-v7a`, `arm64-v8a`, and `x86_64`. The fresh
compiled libraries, ELF build IDs, packaged libraries, and native guard symbols
were checked in `final-profile-identity.json`.

The final debug APK was installed through the default emulator launcher. The
NerdVPN server still showed Logged in, and authenticated subscriptions and
history both returned HTTP 200. The unsaved official onion setup showed
SOCKS and API key instructions. With Tor Browser absent, its open button showed
the copyable preferences address and separate browser guidance. The form was
discarded without entering a key or saving a server. The emulator returned to
NerdVPN Music Home. See `tor-browser-missing-guidance.png` and
`restored-nerd-music-home.png` in the evidence directory.
