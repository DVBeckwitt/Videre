# Videre

[![License: AGPL v3](https://shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0.en.html)

Videre is an independently maintained Android, tablet, and TV client for [Invidious](https://invidious.io), a privacy-focused YouTube frontend.

It is a fork of [Clipious](https://github.com/lamarios/clipious), originally created by Paul Fauchon and contributors. Videre is now maintained by DVBeckwitt and is not affiliated with Google, YouTube, Invidious, or the original Clipious maintainers.

## How it works

Videre connects to an Invidious instance selected by the user instead of communicating with YouTube as a normal YouTube app. You can use a public instance or host your own.

A YouTube account is not required. Invidious accounts, subscriptions, and preferences belong to the selected instance. Privacy and reliability therefore depend partly on that instance and its operator.

## Features

* Public and self-hosted Invidious instances
* Subscriptions, playlists, viewing history, and progress tracking
* Background, audio-only, live-stream, and Android TV playback
* Video and audio downloads
* SponsorBlock, DeArrow, and Return YouTube Dislikes
* Video filtering
* Swipe navigation between phone home tabs
* Swipe navigation between video tabs, including after autoplay
* Swipe down to minimize expanded phone playback
* View, search, seek through, and copy transcripts when captions are available

## Install

Download Videre only from the official [GitHub Releases page](https://github.com/DVBeckwitt/Videre/releases/latest).

Each release includes a universal `app-release.apk` and smaller architecture-specific APKs. Use the universal APK unless you know which architecture your device uses. Android may ask you to allow installation from the browser or file manager that opens the APK.

Videre is not currently published on F-Droid, IzzyOnDroid, Accrescent, or Google Play. Clipious store listings are not Videre releases.

### Obtainium

Add the repository as a GitHub source:

```text
https://github.com/DVBeckwitt/Videre
```

Obtainium can then track new GitHub releases. Android can update an installed APK only when the new APK uses the same signing key.

### Android TV

Install the same release APK directly or track releases through Obtainium. Store-specific Clipious instructions do not apply unless Videre is explicitly published through that store.

## Build from source

```bash
git clone --recurse-submodules https://github.com/DVBeckwitt/Videre.git
cd Videre
./submodules/flutter/bin/flutter pub get
./submodules/flutter/bin/flutter build apk
```

If the Flutter submodule was not cloned:

```bash
git submodule init
git submodule update
```

Build output is written to:

```text
build/app/outputs/flutter-apk/
```

Files in `lib/l10n/generated/` are intentionally untracked. `flutter pub get` regenerates them from `lib/l10n/*.arb` using `l10n.yaml`.

## Development

Enable the repository's pre-commit formatting hooks:

```bash
./submodules/flutter/bin/dart run tools/setup_git_hooks.dart
```

The project pins Flutter as a submodule for reproducible builds. An Android SDK and a device or emulator are also required.

Keep the repository lean. Remove unused files, obsolete code, and commented-out alternatives rather than preserving them in-tree.

### Nix environment

```bash
nix-shell
```

This prepares the development environment and starts a local Invidious server with these test credentials:

```text
user: test
password: test
```

### Tests

Run the complete test suite inside Nix:

```bash
nix-shell --run './submodules/flutter/bin/flutter test'
```

The following regression tests do not require the local Invidious server:

```bash
./submodules/flutter/bin/flutter test test/widget_test.dart
./submodules/flutter/bin/flutter test test/utils/image_object_test.dart
./submodules/flutter/bin/flutter test test/utils/file_db_test.dart
./submodules/flutter/bin/flutter test test/videos/state/video_test.dart
```

### Windows release builds

`tools/build_android_release.ps1` creates signed APKs, app bundles, APK sets, and source archives from Windows. It installs pinned build tools under `%USERPROFILE%\.videre-build-tools` and verifies downloads with SHA-256.

The script never creates a signing key. Point `ANDROID_KEY_FILE` to an existing Gradle signing-properties file stored outside the repository and managed build directories:

```powershell
$env:ANDROID_KEY_FILE = 'C:\secure\videre\key.properties'
pwsh -NoProfile -File .\tools\build_android_release.ps1
```

Validate the directory configuration without downloading tools or reading signing material:

```powershell
pwsh -NoProfile -File .\tools\build_android_release.ps1 -ValidateOnly
```

Run the release-helper regression tests:

```powershell
pwsh -NoProfile -File .\tools\build_android_release.Tests.ps1
```

## Screenshots

Selected screenshots are inherited from Clipious and may not yet show Videre branding.

### Phone

[![Phone home](./screenshots/mobile-home_small.png)](./fastlane/metadata/android/en-US/images/phoneScreenshots/1.png)
[![Phone video](./screenshots/mobile-video_small.png)](./fastlane/metadata/android/en-US/images/phoneScreenshots/2.png)

### Tablet

[![Tablet home](./screenshots/tablet-home_small.png)](./fastlane/metadata/android/en-US/images/tenInchScreenshots/1.png)

### TV

[![TV home](./screenshots/tv-home_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/1.png)
[![TV video](./screenshots/tv-video_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/3.png)

## Issues and contributions

Report bugs through [GitHub Issues](https://github.com/DVBeckwitt/Videre/issues). Include:

* Device model
* Android version
* Videre version or commit
* Invidious instance
* Steps to reproduce
* Relevant logs or screenshots
* Whether the issue also affects Clipious

Code contributions are welcome. Fork the repository, initialize its submodules, enable the formatting hooks, and open a pull request.

Videre does not currently have a separate community chat. Upstream Clipious discussion is available in the [Clipious Matrix room](https://matrix.to/#/#clipious:matrix.org).

## Translations

Videre currently inherits translations from Clipious.

[![Translation status](https://hosted.weblate.org/widgets/clipious/-/app-translation/multi-auto.svg)](https://hosted.weblate.org/projects/clipious/app-translation/)

## Upstream and license

Videre is derived from [Clipious](https://github.com/lamarios/clipious), originally authored by Paul Fauchon and licensed under the GNU Affero General Public License v3.0 or later.

```text
Original Clipious code: Copyright (C) 2023 Paul Fauchon
Videre modifications:   Copyright (C) 2026 DVBeckwitt and Videre contributors
```

Videre is free software licensed under the [GNU Affero General Public License v3.0 or later](./LICENSE). It is provided without warranty. Users are responsible for complying with laws and terms that apply to their use of Videre and their selected Invidious instance.
