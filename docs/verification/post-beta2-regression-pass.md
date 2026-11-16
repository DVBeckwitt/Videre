# Local regression follow-up — 15 November 2026

Reviewed the beta changes against `10125d98`, then repaired additional timing
and policy defects on top of `721f3c93`. The user paused GitHub publication;
these follow-up changes remain local. The earlier release workflow was
cancelled before publication. Its green Build run covers `721f3c93`, not these
later fixes.

## Reproduced defects and repairs

- **Podcast Stop and navigation:** when native Stop completed after Back or
  Close dismissed the controls, it could pop the underlying Library page.
  Completion now closes only the still-current controls route.
- **Covered dialogs:** a shared link opening another route over Takeout or
  Add Podcast could discard the completed operation and leave an endless
  spinner. Active dialogs retain results while covered, and cancellation or
  completion removes only the dialog's own route. Dismissed dialogs remain
  unable to write results or pop another screen.
- **Replay and Pause:** a delayed seek to replay a completed episode could
  override Pause or restart a replacement episode. Resume now checks the
  captured decoder, generation, and current playback intent after seeking.
- **Playback speed during loading:** a speed change while native setup was
  pending could update the UI without reaching the decoder. Setup reconciles
  the latest speed before declaring the source ready.
- **Early rewind and Stop:** an explicit seek during player takeover could be
  lost if Stop arrived before the progress store was attached. The fixed
  profile's store is captured before the first await; reading the saved offset
  still waits for the previous player's final checkpoint.
- **Wi-Fi-only downloads:** enabling the existing Wi-Fi-only preference during
  a cellular podcast transfer did not stop it. The toggle now rechecks an
  existing transfer for that profile. Delayed checks cannot cancel a newer
  transfer or override a subsequently disabled preference.

Fourteen focused regressions were added. Tests reproduced the navigation,
covered-dialog, replay, setup-speed, early-rewind, and Wi-Fi policy failures
before repair. The focused dialog suites passed 36 tests; podcast download,
video download-manager, and connectivity suites passed 104 tests. The full
integrated validation and native acceptance results are recorded below.

Independent source reviews covered import/ZIP bounds, atomic library writes,
podcast feed/storage/transport policy, sign-in cleanup and credential rollback,
profile isolation, and the final repair diff. No further actionable defect was
identified within this review scope. This is bounded evidence, not a guarantee
that every possible app behavior is free of defects.

Evidence logs and controlled runtime fixtures are retained locally under
ignored `build/regression-beta2/`. No credentials, account reset, or direct
Google/YouTube requests are needed for these checks.

## Final validation

- Pinned `dart tools/validate.dart`: **3,177 passed**, six optional live-service
  tests skipped. Formatting checked 711 files with no changes. Strict test
  analysis passed; application analysis retained the existing four warnings and
  236 informational diagnostics, with no new findings.
- The final source diff passed an independent review and `git diff --check`.
- Built and signature-verified an x86_64 profile APK with the pinned Flutter
  3.35.3 / Dart 3.9.2 SDK and JDK 21. APK SHA-256:
  `905547e88976de74778b8ff73c3a6ff4bb27730e42af5ecf2ca06928a8b51f0e`.
- An initial incremental Gradle invocation reused the old APK. A verbose build
  forced the Flutter compile task to rerun; its log identifies the changed Dart
  inputs and new native app library. Runtime acceptance used only the resulting
  new APK. The exact cause of Gradle's initial stale-input decision was not
  established; the existing SDK and build configuration were not changed.
- ZIP entry hashes confirm only `lib/x86_64/libapp.so` differs from the previous
  profile APK. Summed compressed payload size remains 69,740,152 bytes. This
  incremental APK is 96,709,183 bytes including packaging overhead; it is a
  local test artifact, not a published release or a fresh release size estimate.

## Android acceptance

Used the existing signed-in Android 16/API 36 x86_64 AVD, installed with
`adb install -r`. Account data was preserved.

- Started a deliberately slow loopback podcast transfer with Wi-Fi disabled
  and Wi-Fi-only off. Enabling Wi-Fi-only in the existing Downloads toolbar
  cancelled that active transfer; the podcast page showed the Wi-Fi message
  and no completed download. Re-enabling Wi-Fi allowed a fresh download.
- Disabled both Wi-Fi and mobile data and removed ADB port forwarding. The
  downloaded episode played without publisher access.
- Selected 1.5× playback speed and left the app behind Android Home. Native
  media snapshots remained `PLAYING` at speed 1.5, advancing from 44,245 to
  55,151 ms. Pause saved 55,673 ms.
- Force-stopped and reopened the app while still offline. Selecting the
  downloaded episode restored exactly 55,673 ms during loading, then reached
  `PLAYING` at 58,914 ms.
- Sought to the end and completed the episode. Replay followed immediately by
  Pause remained paused at zero. Stop from the controls sheet kept the Library
  page visible. Deterministically delayed native operations and simultaneous
  Back/Close remain covered by the focused automated regressions.
- With networking disabled, the real file picker opened a local CSV and
  displayed its one-song preview. Cancel retained the Library page and did not
  import the fixture song. Covered-route timing has widget-test coverage.
- After restoring connectivity, the saved NerdVPN account still browsed and
  played a public video; its native session reported `PLAYING` at 53,707 ms.
- Removed the synthetic subscription, downloaded audio, and CSV; restored
  Wi-Fi/mobile data and the original Wi-Fi-only setting; stopped the fixture
  server. Publisher receipts contain no credential headers. Existing accounts
  were not removed or re-created.

The new fixes were not pushed, so GitHub CI has not run against them. No new
release was published. Physical phones/TVs, ARM runtime behavior, fresh
valid-credential NerdVPN sign-in, and the full live Invidious suite were not
verified in this follow-up. No native JVM, dependency, signing, or workflow code
changed; their earlier passing checks are historical evidence only.
