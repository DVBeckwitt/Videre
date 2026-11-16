# RSS podcast verification

Checked on 15 November 2026 in the local working tree on
`codex/takeout-import`, based on `10125d98`. The earlier local Takeout feature
and unrelated work were preserved. This feature has not been pushed or released.

## Behavior and isolation

RSS subscriptions and cached episode descriptions use the current profile's
local database. Explicit Add/Refresh requests use a credential-free publisher
client and the existing network proxy. Podcasts never enter the Invidious
subscription, metadata, watch-history, SponsorBlock, or video-download paths.
Known Google/YouTube destinations and FeedBurner are rejected before connections
and through redirects. No artwork is requested and no production dependency was
added.

Podcast audio shares Android's media session through an explicit publisher
source. Normal video/music sources retain their existing instance-origin rules.
Playback takeover, profile/proxy cancellation, delayed loads, audio interruption,
and offline-file failure behavior have focused regression coverage. A shared
connectivity stream prevents podcast transfers from replacing the existing
video download Wi-Fi listener.

## Automated verification

- Canonical `dart tools/validate.dart`: **3,134 tests passed**, six opt-in live
  skips. The final library UI adjustment was separately rerun: eight passed.
- Final canonical format check: 709 files, zero changes. Final configured
  analysis: zero errors, existing four warnings and 236 infos; no podcast
  diagnostics. Strict regression analysis passed.
- Validation helper: five checks passed.
- Native proxy: **121 JVM tests passed**, including six publisher transport
  cases. Native app importer: **15 JVM tests passed**. Android just_audio Java
  compilation passed.
- Windows release helper: 14 checks passed. `git diff --check` passed.
- Debug x86_64 and profile ARM64, ARMv7, and x86_64 APKs built successfully with
  the pinned Flutter/Dart SDK and JDK 21 on Windows.

## Android acceptance

Used the persistent `Videre_NerdVPN_Test` Android 16/API 36 x86_64 emulator
(`emulator-5596`). Installation used `adb install -r`; no account reset,
uninstall, or profile replacement was performed.

A loopback-only synthetic publisher supplied RSS and a two-minute silent PCM
WAV through a temporary ADB reverse connection. The feed included a blocked
YouTube enclosure; only its valid publisher episode appeared. Request receipts
contained no account authorization, cookie, or companion headers.

- Adding the feed saved its title, publisher, date, and episode locally.
- Native streaming entered PLAYING. With Android Home in front, playback
  advanced from 31,035 ms to 41,603 ms over the background observation.
- While paused, Back 15 seconds changed native position from 87,518 ms to
  72,518 ms exactly.
- Download completed and displayed **On this device**.
- Stopped the app, disabled Wi-Fi/mobile data, removed ADB reverse, and stopped
  the publisher. After restarting, both subscription and download remained.
- The downloaded episode played from local storage. Forward 30 seconds changed
  paused position from 39,872 ms to 69,872 ms. Offline background playback then
  advanced from 69,872 ms to 79,690 ms.
- Removed only the synthetic download and subscription; the player closed and
  both test lists became empty. Restored the original Wi-Fi/mobile settings.

Screenshots, native media-session snapshots, publisher receipts, network-state
records, and logs are retained in ignored `build/podcasts/`.

## Packaging and limits

Incremental packaging initially left 26–30 MB of unused ZIP padding. Regenerating
only profile packaging removed it. Every live ZIP entry's SHA-256 remained
identical across all three ABIs, including all bytecode, native libraries, and
resources. Fresh profile APK sizes are ARM64 67,677,277 bytes, ARMv7 81,849,775
bytes, and x86_64 70,151,225 bytes: approximately 0.19–0.25 MiB above the preceding
Takeout profile artifacts. No feature tests, JUnit classes, or test assets were
packaged; all APK signatures verify.

Runtime acceptance used x86_64 APK SHA-256
`8a3a55573729cc118692164cf9288be8138159b02c8569831591afb1ee86917c`.
The compacted APK with identical live contents was subsequently installed;
its SHA-256 is
`54671e94d0f7929624a0f308f894e6d23834fa73c4072a15b3211bb7e1815608`.
Entry manifests and comparisons are in `profile-before-repack.json`,
`profile-after-repack.json`, and `profile-repack-comparison.json` under that
evidence directory.

Native acceptance used controlled fixtures, not a broad sample of public feeds.
Physical phones/TVs, ARM runtime behavior, Linux CI, and live Invidious tests
were not exercised in this pass. TV controls/layout and cross-player ownership
have automated coverage. See [podcast documentation](../podcasts.md) for format,
storage, download, and backup limits.

## Resume positions follow-up

The same local branch now saves episode positions in a profile-bound local
setting. Streaming and downloaded copies share the episode identifier. Saves
occur on playback actions, backgrounding, and every five seconds while playing;
the store retains up to 2,000 recent episodes. It contains only identifiers,
positions, durations, and completion state. No dependency or network path was
added. Completed episodes restart at zero; unfinished episodes near the end
retain their position. Failed loads and missing downloads preserve prior progress.

Final checks after this change:

- 145 focused podcast/playback tests passed, including 20 new resume regressions.
- Canonical validation: **3,154 tests passed**, six optional live skips;
  formatting checked 711 files with zero changes. Analysis had zero errors and
  the existing four warnings/236 infos; strict regression analysis was clean.
- A new x86_64 profile APK built with the pinned SDK and JDK 21. SHA-256:
  `138610a5bd62dc1d5552641c21b9c27518dc3a6b8e592a58008bbbf34cbcf1af`.
- Read-only lifecycle/store review found no remaining actionable resume issue.

Native acceptance reused the same persistent Android emulator and installed
with `adb install -r`, preserving accounts and existing data:

- Before the fix, stopping at 46,254 ms and replaying restarted at 977 ms.
- With the fix, Android media controls paused/stopped at 53,439 ms. After a
  process restart, selecting the streamed episode restored 53,439 ms during
  source loading, and playback continued from there.
- Downloaded the episode, rewound to 48,830 ms, stopped, and restarted with
  Wi-Fi/mobile data disabled, ADB reverse removed, and the fixture server stopped.
  Offline playback resumed and reported 49,829 ms after loading. The sheet showed
  **On this device**.
- Offline playback advanced from 68,707 ms to 79,453 ms behind Android Home.
  Force-stopped the process without pausing or stopping playback. After another
  offline restart, replay reported 80,314 ms after loading, confirming periodic
  progress survived independently of the earlier stop checkpoint.
- Allowed the offline episode to finish at 120,003 ms. Selecting it again
  restarted near zero (2,058 ms after loading).
- Removed the synthetic download and subscription through the UI, restored
  Wi-Fi/mobile data to their original enabled state, stopped the local fixture,
  and returned to Music Home. No account reset, uninstall, or profile replacement.

Logs, native session snapshots, screenshots, publisher receipts, and artifact
metadata for this follow-up are in ignored `build/podcast-resume/`. Publisher
requests contained no account credential headers. This follow-up was not pushed
or released; physical devices, ARM execution, Linux CI, and live services remain
outside its runtime coverage.
