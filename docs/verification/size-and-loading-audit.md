# APK size and loading audit — 15 November 2026

This bounded pass started from `d5c15bf5c36059a457e590b16ee91acf6d3405f4`
plus the requested DASH-description edit. The unrelated Music UI preview was
preserved. The local audit used no push, publication, release-signing keys, or
account reset. This report records that pre-release validation; subsequent beta
publication is tracked separately by the GitHub release and its workflow runs.

## Changes

- Replaced `ffmpeg_kit_flutter_new_full: 1.2.0` with
  `ffmpeg_kit_flutter_new_min: 1.0.1`. Both contain native FFmpeg n7.1.1;
  package version numbers are not FFmpeg engine versions. Downloads require
  local stream copying and the built-in `mov_text`/`webvtt` subtitle encoders,
  not the full package's external encoder libraries. Do not add a transcoding
  feature without checking the minimal distribution's capabilities.
- Removed unused `flutter_web_auth_2` and `url_launcher` production plugins.
  Existing embedded authentication and address-copy flows remain. The resolved
  URL-launcher platform interface remains a development dependency for negative
  privacy tests. Nine packages were removed and one added; retained package
  versions did not change.
- Excluded the notification package's unused test image from release/profile
  assets. The app's own tests, fixtures, and development tools were not packaged
  in the inspected release APK. Deleting useful test suites would not shrink it.
- Deleted an unreferenced error class and moved legacy Music discovery models
  into test support alongside their only consumer. This clarifies production
  ownership; unreachable Dart was already eligible for AOT tree shaking.
- Music library rows now build on demand. A 1,000-entry widget fixture formerly
  retained 1,000 preconstructed row widgets per list; the builder retains no
  eager row list. Scrolling to and playing the last entry still works. This is
  allocation evidence, not a measured device frame-rate improvement.
- Search lists use their actual query/filter criteria as keys. Channel/playlist
  filters recreate their pagination state; unchanged criteria preserve video
  results across unrelated rebuilds. Late replaced responses cannot overwrite
  the new list.
- Concurrent Popular, Trending, and search calls share HTTP work while retaining
  separate decoded results and per-account/header isolation. Each two-caller
  regression changed from two requests to one. Cache invalidation protects
  against old responses repopulating the cache or removing newer requests.
- Session-validation HTTP waiting is bounded to five seconds before response
  handling. A stalled subscriptions endpoint can no longer block that startup
  stage indefinitely; a late rejection cannot clear saved credentials. This
  does not bound every other startup stage.
- Download cancellation now targets its own native merge session and joins
  execution before delete/profile switching cleans files. Cancellation while
  creating a session prevents execution; a missing session ID cannot cancel
  unrelated sessions.

## Clean release size

Both measurements used the pinned Flutter SDK, the same Windows Android build
environment, default icon tree shaking, R8/resource shrinking, and all three
supported Android ABIs. The baseline was freshly built from an isolated archive
of the starting commit plus the already-requested DASH text. The candidate was
built from the final working tree. Neither used the official release key:
a temporary, project-scoped Gradle initialization override selected the normal
debug certificate for these local release-mode measurements, then was removed.
These APKs are not published release artifacts.

| Universal release-mode APK | Bytes | Decimal MB |
| --- | ---: | ---: |
| Before | 207,406,171 | 207.4 |
| After | 159,079,097 | 159.1 |
| Reduction | **48,327,074** | **48.3 (23.30%)** |

Both final APKs have compact ZIP layouts, with only their 4,096-byte signing
gap. Fresh compiler, intermediate, stripped, and packaged AOT identities match
for `armeabi-v7a`, `arm64-v8a`, and `x86_64`. All 35 candidate FFmpeg library
entries match the installed minimal package; the old plugin classes and test
image are absent. The candidate SHA-256 is
`c41530326c8623c66f80a161a9197c2e603b5963e619bf2590c4e6d377d95730`.
Detailed before/after hashes and build provenance are in
`build/optimization-audit/release-apk-comparison.json`; the final rebuild after
the focus/cancellation follow-up is recorded in
`build/removal-regression/final-release-verification.json`. Its byte size is
unchanged, but every ABI has freshly compiled AOT with a different hash.
The subsequent download-estimate repair was also rebuilt for all three ABIs;
its final receipt is `build/nerdvpn-media-fix/final-release-verification.json`,
with the SHA-256 shown above and the same byte size.
All 22 candidate 64-bit native libraries have 16 KB-compatible ELF load
alignment, and their uncompressed APK entries are 16 KB-aligned, preserving
the baseline's alignment support. This is a static binary check, not a run on
16 KB-page hardware; its receipt is `release-native-16k-alignment.json`.

## Verification

The new regression runs reproduced each repaired defect before the changes;
15 of the 16 added cases failed before their repairs.
The initial canonical validation passed formatting on 684 files, configured analysis,
and 3,001 offline tests with six opt-in live skips. Application analysis retains
240 nonfatal diagnostics (four warnings and 236 infos); strict analysis is clean.
Five validation-helper checks, 14 Windows release-helper checks, and 10 APK
signing-verifier tests passed. The focused privacy suites passed 190 tests with
the new dependency graph. The new search test is included in strict validation;
the existing offline search directory already includes it.

The persistent `Videre_NerdVPN_Test` API 36 x86_64 emulator passed actual native
FFmpeg n7.1.1 mux checks on the final debug code: H264/AAC with `mov_text` in MP4,
and VP9/Opus with `webvtt` in WebM. Both returned zero, and host ffprobe confirmed
their output streams. Cancelling one of two running native sessions joined it
in 200 ms and returned cancellation code 255 while the other kept running; the
other was then cancelled and joined. These are controlled local media/session
checks, not live download throughput or an end-to-end download-manager scenario.
The manager's delete/profile-switch ownership is covered by regression tests.
Task-owned device files, debugger forwards, and the attach process were removed.

The production-shrunk release-mode candidate was also installed with `adb
install -r`, launched, and displayed Music home and Library normally. Existing
account data was retained. The single observed cold launch took 11,431 ms during
other compilation; it is not a comparable benchmark or evidence of a general
startup-speed improvement. Network request counts and lazy row allocation are
the measured loading improvements in this pass.

Local receipts, APKs, fixture scripts, and logs are under the ignored
`build/optimization-audit/` directory. Initial packaging comparisons isolated
48,394,512 bytes of savings, including 44,763,012 FFmpeg-library bytes and the
37,257-byte compressed dependency test image. Those profile packages contained
x86_64 Flutter/Dart and three FFmpeg ABIs, so they are not universal release
measurements. Their identical cached Dart AOT payload was detected before
acceptance; fresh compilation and archive identity checks are required below.

Disk exhaustion interrupted an early build and formatting. The two affected
service files were recovered from the committed originals, their exact patches
reapplied, and all checks rerun successfully. Only regenerable native build
intermediates were removed. Saved evidence, old release artifacts, unrelated
working changes, and the persistent signed-in AVD were preserved.

Incremental Android packaging also retained an obsolete unreferenced ZIP slot
after replacing `libapp.so`. Its roughly 26 MB of padding was not runtime code.
Final size comparisons require clean APK packaging outputs and fresh AOT
identity, rather than an incremental file length alone.

The pinned SDK's `--no-pub` also skips platform plugin regeneration. A direct
Gradle release build, or switching from debug to release with `--no-pub`, retained
a debug registrant that referenced a dev-only splash plugin. Normal
`flutter build apk --release` regenerated the release metadata and passed.
No SDK changes, dependency upgrades, or weakened checks were used to repair
that local build procedure.

## Remaining findings and limits

### Follow-up removal regression pass

An independent review after the cleanup found and repaired two defects:

- Lazy music bookmark rows lost keyboard/remote focus when an earlier row was
  removed. Key-to-index lookup now preserves surviving row state without eager
  widget construction. Two widget regressions cover artist rows and mixed
  local/saved playlist rows.
- FFmpeg resets its native cancellation flag when a queued worker starts. A
  single cancellation could therefore miss that start. Cancellation now retries
  for the owned session every 100 ms until execution joins; calls are serialized,
  the timer is stopped, and outstanding cancellation is joined before cleanup.
  The regression models the native flag reset and proves retries stop afterward.

The final canonical run passed **3,004 tests**, with six opt-in live tests
skipped; formatting checked 685 files without changes. Strict analysis remained
clean; library analysis retained the same four warnings and 236 informational
diagnostics. Five validation-helper, 14 Windows release-helper, and 10 APK
signing-verifier checks passed. Android native JVM tests passed 115 cases.

Native instrumentation on the persistent Android emulator passed 30 cases, with
two optional real-Orbot checks skipped. These cover controlled SOCKS playback
and seeking, browser/media privacy, gateway cookies, encrypted account storage,
and NerdVPN key transport. The instrumentation package is distinct from Videre
and uses fixture accounts; it did not reset or change the saved main-app account.

The final debug build also validated the saved live NerdVPN session and loaded
subscriptions, popular/trending feeds, video/channel/playlist search, and video
metadata. Before/after checks confirmed the selected account, profile, stored
credentials, and custom headers were unchanged. These successful requests are
acceptance evidence, not a general network-speed benchmark.

Live progressive playback advanced the native decoder without an initial error.
A later pause/seek/resume sample reported a source error; audio subsequently
reached native playing state in the background, but sustained background progress
was not established. These do **not** constitute a clean seek/background-audio
acceptance pass. The original local video progress was restored.

Live download acceptance was bounded to three attempts. The first failed; the
second transferred data but did not finish within 120 seconds; the shorter-video
attempt failed during metadata retrieval. None established successful end-to-end
offline playback. A direct UI comparison in the preserved **pre-cleanup release**
also failed downloading the same video as MP4 at the same requested quality.
This reproduces a baseline live-download problem, not a new cleanup regression;
its underlying server/transport cause remains undetermined. The candidate's
transfer paths and HTTP dependency versions are unchanged. All task-created
download records/files were removed, including the baseline UI fixture; the
Downloads screen was verified empty afterward. Accounts were never reset.

The final all-ABI release-mode build passed after both follow-up fixes. Fresh AOT
identities match compiler/intermediate/stripped/APK outputs for every ABI. The
minimal FFmpeg libraries, preserved icons, excluded test fixture/unused plugins,
compact ZIP layout, and 16 KB alignment were rechecked successfully. The temporary
project-scoped debug-signing override was removed. No APK was published.
The final APK was installed with `adb install -r` after the baseline comparison
and rendered Music home normally. The signed-in AVD and its data were retained.
The task's debugger attachment was stopped; independent pre-existing emulator
forwards were left alone.

Follow-up receipts and logs are under `build/removal-regression/` (ignored).

### NerdVPN media follow-up

The subsequent request specifically covered the remaining download, seeking,
background-audio, and offline-playback gaps. Current account credentials were
reused; no accounts or app data were reset. Read-only Dart/native transport
reviews found no confirmed client transport defect. Fresh, account-scoped
requests successfully read both initial and nonzero bounded media byte ranges.
No signed URLs, credentials, or response bodies were exported by these probes.

The production download manager then completed the same MP4/240p sample
(`tV5UilNUYRY`) in **294.4 seconds**, including native FFmpeg muxing. Its audio
track was **8,860,752 bytes**, video track **1,410,703 bytes**, and final MP4
**10,425,942 bytes**. Actual partial-file lengths advanced throughout; a debugger
observer saw no terminal download exception. ffprobe confirmed H264/AAC streams
and 547.46-second duration, and a full decode completed with exit code zero.
The earlier 120-second incomplete attempt was not sufficient to classify this
source as stalled. This success does not establish the cause of earlier failed
requests or guarantee the remote service cannot fail again.

One concrete download UI defect was repaired: quality estimates displayed only
the video track size. The sheet now includes the selected compatible audio track,
updates for language/container changes, and hides an estimate when either size
is unknown. A widget regression failed before the fix with **1.41 MB** instead
of **10.3 MB**; the corrected value was also observed in the native download UI.
No transport timeout, privacy rule, authentication behavior, or playback
algorithm was changed speculatively.

Fresh native acceptance on the persistent Android 16 x86_64 emulator passed:

- **Offline:** both Wi-Fi and mobile data were disabled. The downloaded file
  advanced the native decoder, paused at a stable position, and resumed after
  seeks to 120 seconds and back to 8 seconds. Source type remained `file`.
- **Online DASH:** native decoding and both seek directions passed, retaining
  the same player/source and reporting six quality tracks and one audio track.
- **Online progressive:** with DASH temporarily disabled in memory, both seek
  directions passed on the progressive source, without a fallback to DASH.
- **Background audio:** the normal video-to-audio conversion advanced the
  native audio player. During a 70.57-second screen-off observation, the same
  source remained ready/playing without an error; Android audio-frame counters
  also advanced. Media-session Pause held the native position stable and Play
  resumed progress. This debug-emulator observation is not a real-time audio
  quality or physical-device performance benchmark.

Playback probes now bind the requested video and current owner, wait for native
readiness/recovery, and compare samples from the same source. A transient absent
native sample is no longer treated as an error. The prior seek/source failure
did not recur; its intermittent cause remains unproven. The successful checks
close the previous acceptance gaps for these exercised paths, rather than
establishing universal server reliability.

Network settings, the DASH preference, and the original local video progress
were restored. The task-created download was removed after offline acceptance;
the breakpoint observer removed its breakpoint/forward and did not leave the
app paused. Evidence is under `build/nerdvpn-media-fix/` (ignored), including
`download-completion.json`, `offline-acceptance.json`, `online-acceptance.json`,
`progressive-acceptance.json`, and the corrected native UI screenshot.

After the estimate repair, canonical validation passed **3,006 tests** with six
opt-in live skips, formatting on 685 files, and clean strict analysis. Library
analysis retained the same four warnings and 236 informational diagnostics;
five validation-helper checks also passed. The fresh final all-ABI release-mode
APK retained the measured 23.30% size saving and passed AOT, packaging, minimal
FFmpeg, icon, fixture-exclusion, and 16 KB alignment checks. No release was
published and no hosted CI run was created.
That final APK was installed with `adb install -r` and verified at Music home;
the task's remaining debugger forward was removed.

### Deferred baseline findings and environment limits

- Audio-only adaptive format selection currently ranks tracks by bitrate without
  grouping by the declared default language. A higher-bitrate dubbed track can
  be selected. This needs its own default-versus-dubbed regression and language
  acceptance before changing playback selection.
- Optional DeArrow enrichment can still delay a successful list while waiting
  for an unbounded metadata/thumbnail request. A bounded fallback requires
  preserving the user's title/thumbnail preference and cache correctness.
- The broad Android drawable keep rule remains. Narrowing it requires proving
  that dynamically resolved audio-service and notification icons survive R8
  and resource shrinking. Existing per-ABI release APKs remain the appropriate
  smaller downloads for known device architectures.
- Windows-local checks do not establish Linux CI, the Nix-backed full live
  Invidious suite, physical-TV behavior, or broad server/device performance.
  No exact-commit hosted CI run was created during the local audit, before the
  subsequent request to publish a beta.
