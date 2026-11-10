# Bug and regression pass — 10 November 2026

This pass reviews the uncommitted changes following
[playback recovery follow-up](playback-recovery-followup.md). Existing work and
the persistent NerdVPN test account were preserved. JavaScript-dependent sign-in
remains outside the requested scope. No push, merge, or release was performed.

## Repairs

- **Focus interruptions and decoder changes.** Audio/video replacements now
  retain the user's Play intent across a temporary interruption. A sequence of
  ducking and pause interruptions preserves the original intent even after the
  native decoder reports Pause. Replacement audio that mounted while blocked
  receives a resume command when focus returns. Ordinary audio ducking remains
  ungated. Permanent loss, a later user Pause, a new occurrence, and profile
  changes still cancel automatic resume. Audio's local pause gate also releases
  when a pause interruption changes into ducking and then ends.
- **Explicit audio retry.** Play after a terminal online audio failure now uses
  the parent's coalesced fresh-metadata retry. It preserves the queue occurrence,
  latest seek, later Pause, and manual backend choice; explicit Retry resets the
  bounded recovery budget. Failed metadata remains actionable, and an obsolete
  result cannot replace a newer queue selection. Offline Play reloads locally.
- **Recovery feedback.** Audio backend-success feedback now requires advancing
  native playhead samples. The animated Dart position stream cannot claim that
  a stalled decoder recovered. Paused-ready feedback remains available.
- **Seek and source ownership.** Quality changes preserve a user seek still
  awaiting native completion. River rejects obsolete seek completions and
  position polls after a source or seek changes. An old long-video seek cannot
  finish or skip a replacement short video, overwrite its position, or clear its
  pending seek target.
- **Music navigation.** Clearing route arguments on the same mounted Music
  screen invalidates its pending request and retry feedback. Late metadata cannot
  autoplay the abandoned link. Already loaded browsing and playback state remain
  intact. Both phone and TV variants have regression coverage.
- **Metadata admission.** Every service metadata entry point rejects a response
  for a different video before processing or source admission. Music preserves
  its catalog error contract for malformed or mismatched metadata.
- **Legacy NerdVPN credentials.** Server preparation migrates legacy keys before
  playback or Music captures a connection snapshot. It preserves the original
  database, profile, session, proxy, and account boundaries across asynchronous
  work. Existing stale manual snapshots remain refused.

## Privacy and review boundaries

The native transport review found no new actionable defect in initial requests,
redirects, proxy/DNS failure handling, adaptive media children, DRM, local
manifests, embedded-browser closure, or external handoffs. Known official YouTube
destinations remain blocked by the existing Dart/native transport controls;
direct playback and catalog fallback remain unavailable. This pass adds no
network destination or exception to those controls.

HTTP 403 remains terminal for automatic recovery. Its status alone cannot
distinguish an expired media URL from an access refusal. An explicit user retry
may obtain fresh metadata through the selected instance without weakening that
boundary.

## Regression evidence

Local evidence is retained under `build/bug-regression-pass/` (ignored by Git).
Focused failing cases were captured before their repairs for mode changes,
Music route clearing, seek/source replacement, stale position polls, service
admission, and Music credential migration. Parent nested-focus coverage was
added after static reproduction; it has no separate retained red run. The
initial audio red/green observations are tool outputs; the later audio batch has
retained logs.

The first full validation run (`canonical-validation.log`) found two additional
integration failures: the catalog exception contract changed when the service
began rejecting mismatched IDs, and the new offline-retry test assumed eight
event-loop turns were enough for real filesystem I/O. The catalog contract was
restored. The offline test now waits for actual source admission, keeping all
original playback and no-network assertions; its parallel 234-test batch passed.

## Bounded investigation of the earlier audio 403

Before changing the installed APK, two fresh loads of the reported video
`tV5UilNUYRY` succeeded on the previous `2782978c…6ca160` artifact: one from its
saved 159-second position and one explicitly from zero. Both selected itag 251
through HTTPS NerdVPN `/videoplayback`; no new 403 appeared. Signed query values,
credentials, and account headers were not exported.

This argues against a deterministic resume-only failure in those attempts. The
entry paths differed, and the exact HTTP Range header was not observed. It does
not establish the cause of the earlier 403 or prove that it cannot recur.
Receipt: `audio-403-native/receipt.json`.

## Final local validation and build identity

- Pinned `dart tools/validate.dart`: **2,622 tests passed, 4 opt-in live tests
  skipped**. Formatting checked 664 files with zero changes. Configured analysis
  passed: application analysis has 242 nonfatal diagnostics; strict analysis is
  clean. Log: `canonical-final.log`.
- Validation-helper tests: **5 passed**. Windows release-helper tests:
  **14 passed**. APK-signing tests: **10 passed**. Default-emulator launcher safety
  tests: **11 passed**. Final `git diff --check` passed.
- `:videre_proxy:testDebugUnitTest` passed as up-to-date for unchanged native
  inputs. Its 12 suite reports contain **100 tests, no failures or errors**. This
  is cached native-test evidence, not a claim that those tests re-executed in this
  pass. Dart privacy/transport tests ran in the canonical suite above.
- Forced fresh debug compilation and APK assembly passed. The packaged kernel
  matches fresh pinned-SDK output; the native destination, browser, protocol,
  cooldown, and progress controls are present in the DEX. Production source
  hashes remained unchanged during compilation and packaging.
- Profile APKs for `armeabi-v7a`, `arm64-v8a`, and `x86_64` built successfully.
  Forced fresh AOT output matches the merged libraries; ELF build identities
  survive stripping, and the packaged libraries match stripped output. All
  three include the native controls above. Logs: `profile-force-compile.log`
  and `profile-build.log`; the verification is in `build-identity.json`.

Debug artifact: `build/bug-regression-pass/app-debug-regression-pass.apk`.
SHA-256: `38485788407c4eab900dc5a1538ad9b2cf1afd97013928bc5b3f0a4d7e5ef70d`.
Source fingerprint:
`6bea2bdcbfecf1bfc1b97d52e017dad0ae3cd3c39c22ab0bd9b067dbd5e5dccb`.
The 740-file manifest and package verification receipt are `source-manifest.json`
and `build-identity.json` in the evidence directory. Base HEAD remains
`40826fd6187977cd5c7a93f9a36627ef58c2e21d`; the working tree is uncommitted.

## Final APK Android acceptance

The final `38485788…5ef70d` APK was installed with `install -r` on the persistent
`Videre_NerdVPN_Test` emulator (`emulator-5596`, Android 16/API 36). Saved NerdVPN
authentication continued to work. The reported video `tV5UilNUYRY` decoded in
video mode; a paused seek measured 118.505 seconds in the controller. Switching
from paused video to audio preserved that exact position, and explicit Play
started the selected NerdVPN HTTPS media-proxy source (itag 251).

During the 90-second screen-off check, native playhead advanced **90.452 seconds**
and the app's 48 kHz AudioTrack independently consumed **90.440 seconds** of
frames. Android reported Asleep at the 5/30/60/90-second observations. The source
revision stayed unchanged, no native error appeared, and the partial wake lock
remained held. Media-session Pause produced zero playhead/frame advancement;
Play resumed by 2.557 seconds while Android stayed asleep. These were media
session commands, not a physical lock-screen-card tap. Receipt:
`native-final/screenoff-summary.json`.

On `invidious.dvbeckwitt.duckdns.org`, a fresh Music song selection played through
that instance's HTTPS `/videoplayback` route. Native position advanced from
6.012 to 9.074 seconds with no error before pausing. The artwork and wrapped
Korean title rendered cleanly; unavailable channel images used local initials.
Evidence: `native-final/dv-audio-first.json`, `dv-audio-second.json`, and
`dv-music-paused.png`.

The quality menu rendered six 144/240/360p tracks. Its saved preference was
unset/automatic and the menu had no Auto row to restore that state, so no quality
mutation was performed. Quality/seek race acceptance is therefore automated-test
evidence, not a claim of changing quality on this final APK. TV device navigation
was omitted from this bounded run; the new phone/TV Music route regressions and
existing TV widget checks passed in the canonical suite.

The installed APK hash matched the artifact above. The emulator was restored to
NerdVPN Music Home with saved authentication retained, no active playback, no
ADB forward/reverse mappings, phone mode, Fit, automatic quality, and its original
540 × 1080 / 240 dpi display settings. Proxy configuration stayed unchanged.
The complete receipt is `native-final/native-acceptance-receipt.json`.

## Verification limits

Builds and local checks ran on Windows with the repository-pinned Flutter SDK
and JDK 21. Linux-hosted CI and the complete Nix-backed live integration suite
were not run. No remote checks were triggered because nothing was pushed.

There is no reliable existing native focus injector in this test environment.
Temporary/nested focus races therefore have deterministic automated coverage;
the device checks do not claim to reproduce an incoming-call interruption.
No stream failure occurred on the final APK, so terminal-Play recovery,
credential migration, abandoned-route cancellation, and deliberately delayed
seek/poll completions rely on the automated regressions rather than a forced
live failure. Audio-to-video return was tapped but not separately measured as
a complete roundtrip.
Native playhead and consumed audio-frame measurements do not establish physical
speaker output. The original user's physical-device/4G symptom remains
unreproduced on that hardware.

Live onion probes were not repeated in this pass. The preceding bounded Tor
probe reached Tor successfully but timed out at NerdVPN's onion service; earlier
native SOCKS fixtures and their limits remain documented in the playback
follow-up. Those are not presented as fresh full-app onion acceptance for this
APK. No account reset, credential export, proxy bypass, or direct YouTube
fallback was used to obtain a passing result.
