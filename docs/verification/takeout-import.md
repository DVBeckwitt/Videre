# Local Google Takeout import verification

Checked on 15 November 2026 on `codex/takeout-import`, based on `10125d98`.
The feature imports local Takeout song references into the current profile's
Music library. It does not import audio, sign into Google, or synchronize likes.

## Local-only behavior

- Android requests a local document and rejects remote/cloud provider URIs
  before querying or opening them. ZIP contents are read without extracting
  archive paths; file size, entry count, UTF-8, and CRC checks bound processing.
- The Dart parser has no network or file-system client. It retains song IDs and
  text labels, never exported artwork or playback URLs. Missing playlist labels
  can come only from matching Music library records in the same archive.
- Import merges in one queued database write, preserving existing bookmarks and
  metadata. Duplicate IDs are ignored; validation/capacity failures cannot leave
  a partial import. The operation remains bound to its original profile.
- Dialog tests forbid both HTTP client creation and Invidious service requests
  through preview, confirmation, cancellation, and error paths. No production
  dependency was added; JUnit is a native test-only dependency.

## Automated checks

- Pinned `dart tools/validate.dart`: formatting passed, configured analysis
  passed with the existing four application warnings, and **3,058 tests passed**
  with six opt-in live skips. Strict regression analysis was clean.
- Gradle `:videre_proxy:testDebugUnitTest :app:testDebugUnitTest`: **115 transport
  tests and 15 importer tests passed**, with no failures, errors, or skips.
- Windows release helper: **14 safety checks passed**.
- Debug x86_64 APK and profile APKs for ARM64, ARMv7, and x86_64 built successfully.
- `git diff --check` passed.

## Android acceptance

Used the persistent `Videre_NerdVPN_Test` Android 16/API 36 x86_64 emulator
(`emulator-5596`) with its saved profile intact. The debug APK was installed with
`adb install -r`. Tested APK SHA-256:
`3e3732b007e6f8252f934a75d3dbc66e5d905f4a429b458eb5f10e2e46b922aa`.

With Wi-Fi and mobile data both disabled, the real Android file picker opened
fixtures from Downloads. A ZIP containing Liked Music IDs and separate Music
library labels previewed the correct two-song collection and local labels.
Cancel left Songs empty. Confirm added both songs in playlist order, and the
Songs screen displayed their titles and artist without artwork requests.

An overlapping CSV reported one invalid and one duplicate row. Confirming it
reported zero added and two already present; the existing order was preserved.
Only the two task-created song bookmarks and fixture files were then removed.
The original Wi-Fi and mobile-data settings were restored; accounts were not
reset or removed.

Logs, test XML, screenshots, network-state receipts, fixtures, and profile APK
hashes are retained locally under ignored `build/takeout-import/`.

These checks used synthetic exports, not the user's actual archive. TV dialog
layout/focus has widget coverage, but no physical TV acceptance was performed.
Live Invidious integration and Linux CI were not run for this local change.
The feature has not been pushed or included in a new published beta.
