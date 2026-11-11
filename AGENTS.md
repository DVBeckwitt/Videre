# Videre working instructions

- This is a Flutter application for Android phones, tablets, and TVs. Use the
  repository-pinned SDK in `submodules/flutter`; initialize it with
  `git submodule update --init` and restore packages with its `flutter pub get`.
  Do not substitute a globally installed Flutter or change dependency versions
  just to make a check pass. See `README.md` for JDK and Android SDK requirements.
- The canonical local checks are
  `./submodules/flutter/bin/dart tools/validate.dart` (Windows: `dart.bat`). The
  `format`, `analyze`, and `test` arguments run individual stages. Formatting is a
  check and does not rewrite files. Keep the offline test targets in this helper
  synchronized with intentional coverage changes; CI calls the same helper.
- When changing the validation helper, also run
  `./submodules/flutter/bin/dart tools/validate_test.dart`.
- `.github/workflows/build.yml` additionally builds a profile APK on Linux and
  runs `tools/build_android_release.Tests.ps1` on Windows. These are separate
  requirements; passing the offline helper does not establish APK or release
  safety. Signed release instructions and credentials stay in the README and
  existing release helper. Never commit signing material.
- The full test suite includes live Invidious integration tests. Use the existing
  `nix-shell` setup when those are relevant; an offline pass does not cover them.
- For user-facing playback, background audio, downloads, notifications, touch,
  or TV remote/focus changes, obtain relevant Android device/emulator evidence.
  Browser results do not establish native behavior. State any unavailable runtime
  checks and distinguish model/widget tests from actual device acceptance.
- On Windows, default native acceptance to the persistent signed-in NerdVPN AVD
  `Videre_NerdVPN_Test` (`emulator-5596`) via
  `pwsh -NoProfile -File ./tools/start_test_emulator.ps1`. Its AVD home is
  `%LOCALAPPDATA%/Videre/testing/avd-home`. Reuse its saved account and data;
  never wipe, reset, uninstall, recreate, or remove accounts as routine test
  cleanup. Optional `-ApkPath` performs only a data-preserving `adb install -r`.
  See README setup when the existing AVD is unavailable; report missing runtime
  access instead of silently substituting a fresh device. Offline tests and CI
  do not require this local AVD or NerdVPN sign-in. After launcher changes, run
  `pwsh -NoProfile -File ./tools/start_test_emulator.Tests.ps1`.
- Preserve unrelated changes, generated-file conventions, and existing behavior.
  Read the global CI-completion rule before an authorized push: inspect checks
  for that exact commit, investigate regressions, and report pending or blocked
  checks accurately. This file does not authorize a push, merge, or release.
