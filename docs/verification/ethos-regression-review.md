# Privacy and regression review of the cumulative changes

Reviewed on 10 November 2026 in the existing working tree based on `40826fd6`.
This is one review of the changed functional areas, followed by repairs and
verification of the defects it exposed. It preserves the existing checkout,
saved NerdVPN account, local libraries, pinned SDK, and previous work. There is
no commit, push, merge, or release in this review.

## Per-change review

| Change | Review result |
| --- | --- |
| Standard-Invidious Music catalog | No additional defect in catalog removal, unsupported feature handling, search, channel browsing, playlist pagination, repeated occurrences, or saved-bookmark compatibility. |
| Music song links and discovery playback | Fixed a path that fetched metadata before the player and missed automatic retry. It now reports retry progress and passes the recovered streams and backend budget straight into immediate playback. Stored bookmarks and later selections do not reuse those temporary streams. |
| Mandatory instance media proxying | Reviewed initial source admission, signed queries, original host parameters, and NerdVPN onion rebasing. Removed a native unguarded HTTP fallback for local adaptive sources, and blocked UDP/RTMP/RTSP and other network protocols outside the protected transport. Local file/content/data sources remain supported. |
| Dart/native destination guards | Expanded the official-host policy to shared Google APIs and verified additional YouTube domains. Checks cover redirects, background transport, and adaptive children. Shared Google API batch bodies cannot bypass a path-based check. |
| Configured and system proxy endpoints | Fixed checks that validated the destination but could connect to an official host as the proxy itself. Proxy host spelling must be unambiguous ASCII/punycode/IP; legitimate proxies remain supported. |
| Embedded sign-in and backend browsers | Page JavaScript is disabled to close WebRTC and other script-protocol paths outside the HTTP proxy. Media-integrity and service-worker controls are enforced. Backend discovery reads server-rendered HTML through a bounded protected request with same-origin cookies, cancellation, and no redirects. |
| External and Tor browser links | Removed external application launches. Supported video links still route inside Videre. Other permitted web addresses have an explicit Copy action; official URLs and opaque/custom schemes are refused locally. |
| Onion routing and account isolation | Reviewed HTTP/HTTPS SOCKS enforcement, unresolved destination routing, credential separation, and selected-onion thumbnail/media rewriting. Copying the preferences address preserves manual API-key setup without an uncontrolled browser handoff. |
| Generic metadata retry | Fixed malformed cooldowns and policy refusals falling through to another backend. Reviewed coalescing, deadline/budget limits, account/proxy/session cancellation, exact route/header reuse, and loading/error notice lifetime. |
| DASH probing | Fixed swallowed access refusals, TLS/policy failures, and `Retry-After` values that permitted another source or backend. Foreign-origin manifests are rejected. Ordinary unsupported-manifest fallback remains available. |
| Audio initialization and recovery | Fixed seeks being overwritten while metadata, source, speed, or pitch setup was pending. The latest seek belongs to its playback generation. Reviewed bounded same-instance formats, native buffering state, pause publication, and offline paths. |
| Video startup and terminal errors | Fixed startup ignoring a pending Pause and terminal decoder errors leaving notifications claiming playback. Terminal Pause commands preserve the actionable error instead of replacing it with a ready state. |
| Explicit Retry and notification Play | Failed retries retain the current queue occurrence, position, and error. Repeated commands share one attempt. Success honors pending seeks and Pause. Manual per-video backend choices survive retry when their account is still current. Offline retry preserves position without metadata requests. No new automatic mid-playback reconnection loop was added. |
| Caption endpoint fallback | Fixed TLS/privacy refusals and server cooldowns triggering another caption route. Reviewed same-origin track selection, redirect refusal, response deadlines, body limits, and original account ownership. |
| Transcript conversion and subtitles | Fixed Copy decoding normalized text twice and deleting literal angle-bracket text. Reviewed cue timing, repeated lines, entity escaping, paused rendering, stale selection, and disposal. |
| Artwork and downloads | Fixed unsupported preferred cover art hiding a usable smaller cover or video thumbnail. Reviewed image proxying, account-scoped headers/cache, credential-free bookmark persistence, admitted download formats, resume identity, and cancellation. The pinned FFmpeg local-file restrictions did not substantiate the suspected mux-network bypass. |
| Display modes and settings | No additional defect found in Fit/Crop/Stretch/aspect choices, video-only scaling, profile/session guards, legacy preference mapping, or backup validation. Old direct-playback preferences cannot re-enable direct playback. |
| Backend labels and retry notices | No additional defect found in control visibility, phone/TV behavior, hidden semantics, focus, pointer pass-through, notice priority, or cold-start hosts. |
| Phone/TV layouts | No additional defect found in the changed mini-player bounds, statistics wrapping, TV history/grid cards, empty playlist cards, or artwork fallback callsites. |
| Persistent testing environment | Launcher review and isolated fixtures confirmed reuse/install-r behavior, identity mismatch refusal, environment restoration, and absence of wipe/uninstall/reset actions. Saved credentials remain within the local emulator. |
| Documentation and validation | Updated current privacy/browser guidance and added the changed DASH regression file to strict validation. Historical verification documents retain their original tested behavior and artifact identities. |

## Compatibility and privacy boundary

The application has no direct-playback setting or direct-catalog fallback.
Requests to classified official destinations are refused before connection,
including when a blocked host is configured as a proxy. The selected Invidious
server still contacts YouTube upstream. Independent services already supported
by the app, such as SponsorBlock, retain their own routes and preferences.

Embedded JavaScript-dependent login and backend-check pages are unsupported.
Basic HTML forms and server-rendered backend pages are the supported browser
contract. A failed new sign-in must not erase the last completed session.
External addresses can be copied, but opening them in another application is
outside Videre's networking. Videre does not initiate that handoff.

The hostname controls do not establish who owns every arbitrary configured IP
address or DNS alias, and cannot certify future unknown domains or defects in
the operating system. This report describes the enforced paths and measured
tests, not an unconditional proof about every possible Internet destination.

Primary references used for the browser boundary and domain classification:
[Chromium peer connections](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/modules/peerconnection/peer_connection_dependency_factory.cc),
[RFC 8828](https://www.rfc-editor.org/rfc/rfc8828.html),
[Android WebSettingsCompat](https://developer.android.com/reference/androidx/webkit/WebSettingsCompat),
[Education player](https://workspaceupdates.googleblog.com/2023/10/changes-to-youtube-player-embedded-in-.html),
[YouTube Kids](https://support.google.com/youtubekids/answer/7348648),
[YouTube TV linking](https://support.google.com/youtube/answer/3015415),
and [Google registry](https://www.registry.google/faqs/).

## Verification

- Pinned `dart tools/validate.dart` passed formatting, configured analysis, and
  **2,454 offline tests**, with four opt-in live skips. Application analysis
  retains 247 nonfatal diagnostics; strict regression analysis reported none.
  Log: `canonical-validation.log`.
- Validation-helper tests: five passed. Persistent-emulator launcher fixtures:
  11 passed. Windows release-helper safety fixtures: 14 passed. APK-signing
  identity fixtures: 10 passed. No signing material was printed or produced.
- Final native JVM suite: **98 passed**, with no failures or skips. Native app
  compilation and the separate instrumentation APK build passed.
- Five focused Android privacy cases passed on the exact instrumentation APK,
  including script-disabled HTML form/cookie handling, bounded native page
  reading, blocked local-manifest children, and saved-profile worker blocking.
  Additional SOCKS/playback and gateway suites passed ten cases; two optional
  live-Orbot cases skipped. These use the separate `.proxy.test` package and
  local fixtures, not the real account. No official endpoint was contacted.
- The final debug APK is `app-debug-ethos-audit.apk`, SHA-256
  `2a65db0f7735479a7df03dfdcb72b160790cd69e7a98db3b5011e85dbb3b5fbc`.
  Its packaged Dart kernel matches the fresh compilation, and the native
  destination, browser, page-reader, and media-protocol guards are packaged.
  See `build-identity.json` and `source-manifest.json`.
- Profile APKs for `armeabi-v7a`, `arm64-v8a`, and `x86_64` passed final identity
  checks. Fresh compilation matches merged libraries, ELF build IDs survive
  stripping, and packaged libraries match stripped output. All three include
  the native guards. See `profile-build-identity.json`.

The first profile build command succeeded but reused older AOT output. This was
detected by comparing compiled/merged/packaged libraries and source modification
times. Running the pinned Gradle `:app:compileFlutterBuildProfile --rerun-tasks`
for the three Android architectures, then rebuilding the profile APKs, produced
fresh verified binaries. The production source manifest remained unchanged.
The initial command alone is not counted as verification. Logs are
`profile-build.log`, `profile-force-compile.log`, and `profile-build-fresh.log`.

The first script-disabled browser test also exposed a real compatibility
failure: native JavaScript extraction returned null with page scripts disabled.
That failure led to the protected HTML reader repair. The original failure and
the passing replacement are retained in `native-privacy-initial-receipt.json`
and `native-privacy-final-receipt.json`.

## Integrated Android acceptance

The exact debug APK above was installed through the default launcher on the
persistent `Videre_NerdVPN_Test` AVD, Android 16/API 36 x86_64. The installed
base APK hash was checked. Saved NerdVPN login survived the update; authenticated
subscriptions and history returned HTTP 200 without signing in again.

- NerdVPN's `tV5UilNUYRY` returned metadata and rendered decoded video. Statistics
  fit the phone screen, and controls and the backend badge faded on idle.
- In audio-only mode, the native 48 kHz music track advanced **20.173 seconds**
  while Android reported Asleep. Media-session Pause stopped frame advancement
  and released the wake lock. Play restarted frames and reacquired the lock
  while still asleep. This tests Android media commands; the emulator did not
  expose a keyguard media-control card.
- NerdVPN Music search and playback worked. The compact Korean-title player
  displayed progress and controls without overflow.
- The existing DVBeckwitt instance was temporarily selected. Music search and
  metadata returned 200, and PSY playback advanced from 00:08 to 00:26 before
  pausing. Song artwork rendered; some channel thumbnails showed placeholders.
  A subsequent anonymous probe of the selected instance's officialpsy image
  route returned 302 to `/feed/popular`, then 401 with an authentication-host
  redirect. Neither that off-origin redirect nor the original Google image URL
  was requested. The constructed `/ggpht` route matches the
  [upstream image handler](https://raw.githubusercontent.com/iv-org/invidious/master/src/invidious/routes/images.cr).
  This establishes an unavailable image-proxy response for the sampled channel,
  not an exhaustive diagnosis of every missing image. Evidence:
  `dv-thumbnail-probe.json`.
- The preferences link displayed a copy-only dialog and successful clipboard
  feedback, with no browser launch.
- Forced TV layout at 720 × 360 logical pixels showed the Korean History card,
  channel label, adjacent D-pad navigation, and empty Watch Later card without
  overflow. No library or playlist contents changed.
- The backend picker displayed eight choices and refreshed normally. Server
  default and the existing automatic-fallback preference remained unchanged.

The device was restored to NerdVPN Music Home with Force TV off, 540 × 1080
pixels, 240 dpi, original rotation settings, Fit unchanged, and no playback.
Login, accounts, network settings, backend preferences, and library data were
preserved. No credentials were extracted into testing tools or reports.

The final receipt is `native-integrated-final-receipt.json`; supporting evidence
and artifact receipts are under `build/ethos-regression-audit/`.

## Verification limits

The chosen video advertised no caption tracks, so this final live run does not
repeat earlier caption-rendering acceptance. Caption transport, normalization,
and rendering regressions passed automated checks. Fresh download/offline-file
roundtrip and the full display-mode geometry matrix were not repeated on this
APK. Earlier runtime evidence remains scoped to its original artifacts.

Successful backend discovery meant the app's browser fallback button was not
available. The complete live Use page → Dart picker path was not forced; the
repaired native reader/cookies/forms and Dart selector parser were verified
separately. The earlier automatically rejected initial-metadata Android fixture
was not retried. Initial failure/success and nonretryable response behavior have
model/widget coverage, not a new controlled app-device demonstration here.

There is no physical-TV or physical-OEM-device acceptance and no current live
onion/Orbot playback result. The optional native live-Orbot cases skipped.
Whitelisted response logs support the observed instance routes but are not an
exhaustive packet capture. No official YouTube endpoint probe was sent.

These are local Windows and Android-emulator checks. Linux-hosted CI and the
full Nix-backed live Invidious integration suite were not run. No remote commit
or workflow was created, and no release readiness is claimed for those missing
environments.
