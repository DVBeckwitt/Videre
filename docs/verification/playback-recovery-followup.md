# Playback recovery follow-up

This follows the local changes recorded in `ethos-regression-review.md`.
The requested deliverable is bounded recovery for interrupted playback and
confirmed silent audio stalls, private channel-image fallback, and a fresh
Tor/onion investigation. JavaScript-dependent sign-in is excluded by request.
No commit, push, merge, or release is authorized by this work.

## Implementation plan

1. Preserve the admitted instance/account/proxy snapshot on loaded videos,
   including standard Invidious instances without a backend selector. Keep
   this state and source identity out of serialization.
2. Share a two-attempt same-route refresh budget across the current playback
   occurrence. Delay retries, perform one metadata request per reservation,
   reject stale callbacks, and preserve queue identity, position, play/pause
   intent, speed, pitch, and quality. Existing bounded backend fallback may
   follow a classified transient failure. Access, privacy, TLS, and cooldown
   refusals cannot authorize another route.
3. Integrate audio and video consumers. Show a nonblocking, accessible
   reconnecting notice until native playback resumes or the replacement is
   ready while paused. Terminal failures retain the explicit Retry action.
4. Add a read-only native audio progress sample. Detect stalls only from fresh,
   consecutive observations after demonstrated progress. Exclude seeks,
   interruptions, pauses, source changes, end-of-media, and sampling gaps.
   Use conservative separate thresholds for ready and buffering states;
   never infer a stall from missing callbacks or the extrapolated UI clock.
5. Keep channel artwork on the selected instance. When advertised private
   candidates fail, show a channel-initial avatar without a new route or loop.
6. Bound live Tor investigation to two attempts per official onion endpoint,
   with an independent Tor connectivity check. Distinguish unavailable onion
   services from app routing defects; never bypass the selected proxy.

## Acceptance conditions

Automated regression checks must cover retry exhaustion, cancellation,
nonretryable refusals, preserved user intent and source identity, objective
stall detection, and notice/avatar behavior. Run the repository's pinned
formatting, analysis, offline tests, native checks, release-helper checks,
and Android build. Reuse the persistent signed-in NerdVPN emulator without
exporting credentials or changing its saved account data. Observe playback
and screen-off native audio progress on the final artifact. Record unavailable
physical-device, service, or hosted-CI evidence explicitly.

## Results

The shared refresh API retains the original admitted connection and a source
token. Its two reservations survive successful reloads and audio/video mode
changes. An explicit Retry or a new selection starts a new budget. Metadata
refreshes may retry transient JSON 500/408 responses; alternate-backend
admission retains its narrower existing policy. Native HTTP failures carrying
any `Retry-After` header are refused by both players' recovery classifiers.

Video recovery also closes a quality-switch race: progressive quality changes
now use the same guarded source setup, so a later Pause or focus interruption
cannot be overwritten by the controller's old autoplay snapshot. TV Music's
explicit Retry now uses the shared retry method, including offline playback.

The channel-image investigation sampled three advertised officialpsy sizes
through DVBeckwitt's `/ggpht` route. All returned 302 to `/feed/popular`; no
redirect or original Google URL was requested. There was no supported private
alternative in these observations. Channel avatars now render an initial
while private artwork loads or after its finite candidates fail.

Independent Tor checks returned HTTP 200 and `IsTor=true` twice. NerdVPN's
official HTTP and HTTPS onion roots both timed out without response headers in
two bounded rounds (15 and 20 seconds). This leaves live onion playback
unverified; it is not evidence of an app routing defect. Controlled Android
tests separately proved HTTP onion media decoding/seek/range, HTTPS remote
hostname resolution and TLS initiation, and no direct fallback when SOCKS is
unavailable. Eight cases passed; two optional live cases skipped.

Supporting receipts: `build/onion-live-acceptance/live-tor-receipt.json`,
`build/onion-live-acceptance/native-socks-fixture-receipt.json`, and
`build/ethos-regression-audit/channel-artwork-followup.json`.

## Automated verification and build identity

- The pinned `dart tools/validate.dart` passed all stages: 664 files formatted
  with no changes, configured application analysis (246 nonfatal diagnostics),
  strict regression analysis with no issues, and **2,572 tests passed**, with
  four opt-in live tests skipped. Log: `followup-canonical-final.log`.
- Validation-helper tests: five passed. Persistent emulator launcher safety:
  11 passed. Windows release-helper safety: 14 passed. APK-signing identity:
  ten passed. No signing material was printed or created.
- Native JVM tests: **100 passed**, with no failures or skips. Both native
  player modules compiled. The new native cooldown matrix runs inside the
  existing CI native gate. Log: `native-progress-cooldown.log`.
- Focused checks included 83 audio/stall tests, 26 native-progress wrapper
  tests, 99 video/recovery tests, and 65 artwork/catalog/discovery tests.
  These overlap the final canonical suite and are not additional unique tests.
- Android SOCKS instrumentation: eight passed, two optional live Tor cases
  skipped. HTTP onion decoding succeeded; the HTTPS fixture establishes remote
  DNS and TLS initiation, not successful HTTPS decoding or a live onion service.

The first full run found 16 failures. Investigation corrected a real duplicate
resolution selection bug (the working fallback must retain its exact URL) and
an unnecessary account lookup for empty avatars. Existing audio test doubles
were updated to implement native pause/playing state; their assertions were
retained. The failed run remains in `followup-canonical-validation.log`, followed
by the passing final run. No test or required gate was disabled.

A final focus review reproduced a separate permanent-loss defect: automatic
playback could revive after an end event, while explicit Play without an end
event stayed blocked. Permanent loss now cancels automatic intent; explicit
video Play must obtain a fresh focus grant, and audio uses just_audio's existing
activation request. This follows [Android's audio-focus contract](https://developer.android.com/media/optimize/audio-focus).
Late grants are fenced by video generation, user intent, and focus revision.
Tests also cover denial, a later Pause, newer interruptions, a new selection,
and audio/video mode changes. Red evidence is retained in
`permanent-focus-parent-red.log` and `permanent-focus-edges-red.log`; the final
canonical run includes the complete correction. The earlier passing build and
90-second device receipt remain separately identified below.

The final debug APK is `build/ethos-regression-audit/app-debug-playback-followup.apk`,
SHA-256 `2782978c106715bb8f8f2365ffdc96cad5ad572cfee18c87d17b3641066ca160`.
Its packaged Dart kernel matches fresh pinned-SDK output. Destination, browser,
page-reader, media-protocol, cooldown, and native-progress controls are present
in the packaged native code. The build receipt and production source hashes
are `followup-build-identity.json` and `followup-source-manifest.json` in the same
directory. The working tree is uncommitted; base HEAD remains
`40826fd6187977cd5c7a93f9a36627ef58c2e21d`.

Profile APKs for `armeabi-v7a`, `arm64-v8a`, and `x86_64` built successfully.
Forced fresh AOT compilation matches the merged native libraries, ELF build
identities survive stripping, and the packaged libraries match stripped output.
All three include the native controls listed above. Production source hashes
remained unchanged. Logs: `followup-profile-force-compile.log` and
`followup-profile-build.log`; identities are in `followup-build-identity.json`.

## Integrated Android acceptance

The first integrated debug APK was installed through the default launcher with `install -r`
on the persistent `Videre_NerdVPN_Test` emulator. The saved NerdVPN login still
works; no new sign-in or account export was needed. The reported video
`tV5UilNUYRY` decoded in video mode, then played in audio-only mode.

During 90 seconds with Android reporting Asleep, direct invocation of the new
read-only native wrapper measured **90.586 seconds of playhead advancement**.
The same source revision remained active. Its 48 kHz audio track independently
consumed **90.644 seconds of audio frames**. The partial wake lock remained held.
Pause while asleep produced zero playhead/frame advancement; Play advanced
another 2.567 seconds and reacquired the wake lock. These were Android media
session commands, not a claim about tapping a physical lock-screen card.

The VM measurement did not attach Flutter or compile/evaluate new application
code. It captured only whitelisted numeric/state fields through a temporary
local forwarding connection, which was removed. Receipt:
`build/ethos-regression-audit/followup-native/screenoff-summary.json`.

That pre-correction APK has SHA-256
`63b504502fe78f83a3fb334be77f26ada840cbba1f2cdb4b6162edf603f23da0` and is retained
as `app-debug-playback-followup-before-permanent-focus.apk`. Its own built-in
watchdog also advanced its observations while asleep with the VM connection
closed: 15.999 seconds between samples, matching 15.971 seconds of native
progress. Both-instance Music playback, DVBeckwitt avatar initials, TV History
and empty Watch Later layouts passed, and the default environment was restored.
These measurements are scoped to that earlier artifact. Its immutable receipt
is `followup-native/native-acceptance-receipt.json`.

The corrected final APK (`2782978c…6ca160`) was installed with saved login intact.
The reported `tV5UilNUYRY` decoded in video mode, but its audio-only source
returned HTTP 403. One ordinary Retry fetched metadata successfully, preserved
the 159.517-second position, and received another audio HTTP 403. The player
retained its actionable Retry/backend-choice UI and did not silently rotate
on the access refusal. The cause of that live source refusal is not established;
this exact-video audio check is not counted as a pass.

A fresh NerdVPN Music selection (`9bZkp7q19f0`) recovered from metadata HTTP
500 to 200 after one Songs-row tap, without a manual Retry. It then played for
90 seconds with Android Asleep: **90.545 seconds of native playhead progress**
and **90.576 seconds of independently consumed 48 kHz audio frames**. Pause
produced zero advancement; Play resumed by 2.547 seconds while still asleep.
The same native source revision remained active.

The built-in watchdog, with the external VM connection closed for 15 seconds,
advanced its own sample timestamp by 16.000 seconds and native position by
16.003 seconds. The readback was less than one second old. This verifies that
the background detector is actually polling, independently of the test probe.
Final-artifact receipts are under `followup-native-final/`, including
`screenoff-summary.json`, `watchdog-existing-samples.json`, and
`exact-video-audio-failure.json`.

On the corrected APK, DVBeckwitt Music metadata returned 200 and native playback
advanced from 19.376 to 21.799 seconds before pausing at 21.873 seconds. Song art
rendered and unavailable channel images showed clean local initials.

The device was restored to NerdVPN Music Home with saved login retained, Force
TV off, Fit unchanged, 540 × 1080 pixels at 240 dpi, rotation 0/auto-rotation on,
and no active playback or ADB forwarding/reverse mappings. The final receipt is
`followup-native-final/native-acceptance-receipt.json`, including the verified
installed APK hash. The earlier TV layout evidence remains explicitly scoped
to the preceding APK; it was not repeated after the permanent-focus correction.

## Remaining verification limits

The native snapshot measures ExoPlayer's playhead, not physical speaker output.
The original physical-device/4G symptom has not been reproduced on that user's
hardware. Deterministic recovery/stall and interruption failures were exercised
in automated tests; successful live playback does not reproduce every upstream
failure. The final exact-video audio stream returned HTTP 403 despite successful
metadata and a manual Retry. NerdVPN's live onion service remained unreachable
during the bounded probe, and the sampled DVBeckwitt channel-image route remained
unavailable (the avatar fallback handles its presentation).
Linux-hosted CI and the full Nix-backed live integration suite are unavailable
in this local Windows run. No remote validation, push, merge, or release is
claimed.
