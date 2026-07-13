# Videre

[![License: AGPL v3](https://shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0.en.html)

Videre is an Android client for [Invidious](https://invidious.io), the privacy-focused YouTube frontend.

Videre is a fork of [Clipious](https://github.com/lamarios/clipious) by Paul Fauchon and contributors. This fork is maintained independently by DVBeckwitt and contributors.

Videre is not affiliated with Google, YouTube, the Invidious project, or the original Clipious maintainers.

## Status

Videre is an independent fork of Clipious. I plan on maintaining it for myself but will also be happy to hear bugs from others and address them. 

Official Videre APKs are published from this repository under [GitHub Releases](https://github.com/DVBeckwitt/Videre/releases). Download builds only from the official Videre releases page unless another distribution channel is explicitly listed here.

Videre is not currently published on F-Droid, IzzyOnDroid, Accrescent, or Google Play. Store listings for Clipious are upstream Clipious listings, not Videre listings.

### Current release: 1.22.17

This release prevents instance credentials from reaching external thumbnail origins, improves thumbnail fallback and controls, restores the dark Android splash artwork, refreshes generated platform files, and removes obsolete or duplicated code and assets. No settings or data migration are required.

See [Reported bugs](./REPORTED_BUGS.md) for the upstream issue inventory and Videre verification status.

### Homepage tab navigation

Status: available in the current source and covered by an automated widget test.

On phones, the Home, Subscriptions, Playlists, and History pages can be changed with the bottom navigation bar or a horizontal swipe. Swipes track the finger, snap to one page at a time, and bounce only at the first and last pages. Horizontal drags that start on a Home carousel scroll that carousel; start the gesture elsewhere in the page to change tabs. Tablet and TV navigation behavior is unchanged. The feature uses the existing tab routes and requires no setting, data migration, or user action.

### Thumbnail privacy and fallback

Status: fixed in the current source and covered by offline regression tests.

Videre sends instance authentication headers only to the selected instance's exact HTTP(S) origin, including its effective port. External, lookalike-host, scheme-mismatched, and port-mismatched thumbnail URLs still load, but without instance credentials. Video cards prefer an exact `maxres` thumbnail before the existing fallback order, and their foreground controls remain usable while thumbnails load or fail. The fix requires no setting, data migration, or user action.

### Playback source fallback

Status: implemented in the current source and covered by offline regression tests; it is not part of release 1.22.17, and the upstream reporters' device and instance paths have not been reproduced.

Videre validates and deduplicates HLS, DASH, and progressive sources, retains at most ten ordered candidates, and tries each alternative once when setup fails before initialization. A video switch cancels its Dart-side wait, disposes the obsolete controller, and ignores late completion instead of waiting indefinitely. Progressive quality choices come from the same bounded, validated candidates; duplicate labels prefer the first accepted URL while keeping same-label fallbacks selectable. Retries preserve subtitles, progress, and quality selection; errors after initialization remain terminal.

Playback starts only from the selected instance's exact origin or a default-port HTTPS `googlevideo.com`/`youtube.com` origin. Instance custom headers are not passed to the native media player, preventing them from following redirects or adaptive child requests to another origin. API and thumbnail authentication are unchanged. This is a deliberate security migration: an authenticated reverse proxy that requires custom headers for media must expose unauthenticated media URLs or playback will fail. There is no stored-data migration.

The starting-URL and candidate-count hardening is partial destination containment, not a native network sandbox. The pinned player can still follow redirects and adaptive child URLs beyond the Dart check, including destinations that the starting-URL policy would reject; it receives no instance credentials when doing so. Closing that residual request-forgery risk requires a native player data-source policy.

## How it works

Videre does not talk to YouTube directly as a normal YouTube app. Instead, it connects to an Invidious instance selected by the user. That instance retrieves and exposes YouTube content through the Invidious API, and Videre provides the Android, tablet, and TV interface on top of it.

You can use your own Invidious instance or a public one. Privacy and reliability depend partly on the instance you choose, because the instance operator controls the server that Videre connects to.

Videre does not require a YouTube account. If you use an Invidious account for subscriptions or preferences, that account belongs to the Invidious instance you choose.

## Features

- Use your own or a public Invidious instance
- Subscription management
- SponsorBlock and DeArrow support
- Video view and progress tracking
- Playlists
- Background playback
- Live stream support
- Android TV interface
- Audio playback
- Video and audio download
- Video filtering
- Return YouTube Dislikes support
- Swipe navigation between phone homepage tabs

## Installation

### Download APK

Download the latest APK from the [Videre Releases page](https://github.com/DVBeckwitt/Videre/releases/latest).

Each release provides a universal `app-release.apk` and smaller architecture-specific APKs. Use the universal APK unless you know the device architecture.

On Android, you may need to allow installation from unknown sources for the browser or file manager you use to open the APK.

### Updates

If you use [Obtainium](https://github.com/ImranR98/Obtainium), add this repository as a GitHub source:

```text
https://github.com/DVBeckwitt/Videre
```

Obtainium can then track new Videre releases from GitHub.

Android can update an installed APK only when the new APK is signed with the same signing key as the installed version. Release notes should mention any signing-key changes.

### TV

For TV users, install the APK from the Videre Releases page or track releases with Obtainium. Store-specific recommendations from Clipious do not apply to Videre unless Videre is published through that store.

### Build from source

To build manually:

```bash
git clone --recurse-submodules https://github.com/DVBeckwitt/Videre.git
cd Videre
```

If the Flutter submodule was not cloned, initialize it manually:

```bash
git submodule init
git submodule update
```

Then install dependencies and build with the pinned Flutter version:

```bash
./submodules/flutter/bin/flutter pub get
./submodules/flutter/bin/flutter build apk
```

The APK should be created under:

```text
build/app/outputs/flutter-apk/
```

## Screenshots

Screenshots are inherited from Clipious and may not yet reflect Videre branding.

### Phone

[![Home](./screenshots/mobile-home_small.png)](./fastlane/metadata/android/en-US/images/phoneScreenshots/1.png)
[![Video](./screenshots/mobile-video_small.png)](./fastlane/metadata/android/en-US/images/phoneScreenshots/2.png)
[![Channel](./screenshots/mobile-channel_small.png)](./fastlane/metadata/android/en-US/images/phoneScreenshots/3.png)
[![Playlist](./screenshots/mobile-playlist_small.png)](./fastlane/metadata/android/en-US/images/phoneScreenshots/4.png)

### Tablet

[![Home](./screenshots/tablet-home_small.png)](./fastlane/metadata/android/en-US/images/tenInchScreenshots/1.png)
[![Video](./screenshots/tablet-video_small.png)](./fastlane/metadata/android/en-US/images/tenInchScreenshots/2.png)
[![Channel](./screenshots/tablet-channel_small.png)](./fastlane/metadata/android/en-US/images/tenInchScreenshots/3.png)
[![Playlist](./screenshots/tablet-playlist_small.png)](./fastlane/metadata/android/en-US/images/tenInchScreenshots/4.png)

### TV

[![Home](./screenshots/tv-home_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/1.png)
[![Home](./screenshots/tv-home-2_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/2.png)
[![Video](./screenshots/tv-video_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/3.png)
[![Video](./screenshots/tv-video-2_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/4.png)
[![Channel](./screenshots/tv-channel_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/5.png)
[![Playlist](./screenshots/tv-playlist_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/6.png)
[![Playlist](./screenshots/tv-playlist-2_small.png)](./fastlane/metadata/android/en-US/images/tvScreenshots/7.png)

## Facing an issue?

Open an issue in this repository: <https://github.com/DVBeckwitt/Videre/issues>

When reporting a bug, include:

- Device model
- Android version
- Videre version or commit
- Invidious instance used
- Steps to reproduce the issue
- Logs, screenshots, or screen recordings when useful

If the issue also affects upstream Clipious, mention that in the report.

## Community

Videre does not currently have a separate community chat.

For upstream Clipious discussion, see the original Matrix channel: <https://matrix.to/#/#clipious:matrix.org>

## Contribute

### Code

To get started, create a fork of this repository and run:

```bash
git submodule init
git submodule update
# Enable Git pre-commit hooks for auto-formatting.
./submodules/flutter/bin/dart run tools/setup_git_hooks.dart
```

Keep source and project configuration lean: remove unused files and obsolete commented-out alternatives rather than preserving them in-tree; Git history remains the archive.

Or use Nix, which handles the setup above and starts a working local Invidious instance with user `test` and password `test`:

```bash
nix-shell
```

Flutter is used as a submodule in this repository so the project can pin the Flutter version used for builds. This structure is inherited from Clipious and helps keep builds reproducible.

You will also need an Android SDK and a device or emulator to run the app.

### Windows release builds

Status: the local Windows release helper is available and its path, signing, download-integrity, and checksum controls are covered by automated tests.

`tools/build_android_release.ps1` can create the signed APK, app bundle, APK set, and source archives from a Windows checkout. It installs pinned portable copies of Temurin 21.0.11+10, Gradle 8.7, Android command-line tools 14742923, and bundletool 1.18.3 under `%USERPROFILE%\.videre-build-tools` by default. Every downloaded file is verified against a pinned SHA-256 digest before extraction or execution.

Release signing is never generated by the script. Set `ANDROID_KEY_FILE` to an existing Gradle signing properties file outside the repository and the managed output, work, and tool directories. `storeFile` must also be an absolute path outside those directories.

```properties
storeFile=C:/secure/videre/upload.jks
storePassword=<secret>
keyPassword=<secret>
keyAlias=<alias>
```

```powershell
$env:ANDROID_KEY_FILE = 'C:\secure\videre\key.properties'
pwsh -NoProfile -File .\tools\build_android_release.ps1
```

The default artifact and workspace directories are next to the repository. Work and tool directories are marked with `.videre-release-work` and `.videre-build-tools`, respectively, and only the `checkout` child of the work directory is reset. A non-empty directory without the expected marker is rejected without modification. To migrate from an older copy of the helper, inspect the old work/tool directories and either choose new empty paths with `-WorkDir` and `-ToolDir` or add the appropriate marker only after confirming the directory is dedicated to this script. The former built-in local signing key and fixed passwords are no longer supported.

Generated APK checksum sidecars use SHA-256. A stale `.sha1` sidecar for an APK is removed when that APK is processed. `-SkipToolInstall` is an explicit opt-out of managed downloads and requires all expected tools to already exist under `-ToolDir`.

Validate directory configuration without downloading tools or reading signing material:

```powershell
pwsh -NoProfile -File .\tools\build_android_release.ps1 -ValidateOnly
```

Run the release helper regression checks:

```powershell
pwsh -NoProfile -File .\tools\build_android_release.Tests.ps1
```

### Tests

The app has tests that expect a locally running Invidious server with a test user whose password is `test`.

The easiest way is to use [Nix](https://nixos.org):

```bash
nix-shell
```

That starts a PostgreSQL database, an Invidious server, and the required test user. This is how the tests are run in CI/CD.

You can also run your own test environment with Docker or another setup.

Alternatively, run the tests directly inside the Nix environment:

```bash
nix-shell --run './submodules/flutter/bin/flutter test'
```

The homepage, thumbnail, and playback-source regression tests are self-contained and do not require the local Invidious test server:

```bash
./submodules/flutter/bin/flutter test test/widget_test.dart
./submodules/flutter/bin/flutter test test/utils/image_object_test.dart
./submodules/flutter/bin/flutter test test/videos/state/video_test.dart
```

### Translations

Videre currently inherits translations from Clipious. The badge below tracks the upstream Clipious translation project.

![Translation status](https://hosted.weblate.org/widgets/clipious/-/app-translation/multi-auto.svg)

Upstream translations are handled through [Weblate](https://hosted.weblate.org/projects/clipious/app-translation/).

## Relationship to Clipious

Videre is derived from Clipious.

Original project:

- Clipious: <https://github.com/lamarios/clipious>
- Original author: Paul Fauchon
- Original license: GNU AGPL v3.0 or later


## License

Videre is free software licensed under the GNU Affero General Public License v3.0 or later. See [LICENSE](./LICENSE).

Original Clipious code:

```text
Copyright (C) 2023 Paul Fauchon
```

Videre modifications:

```text
Copyright (C) 2026 DVBeckwitt and Videre contributors
```

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Affero General Public License as published by the Free Software Foundation, either version 3 of the License, or, at your option, any later version.

This program is distributed without any warranty, including without the implied warranty of merchantability or fitness for a particular purpose. See the GNU Affero General Public License for details.

You should have received a copy of the GNU Affero General Public License along with this program. If not, see <https://www.gnu.org/licenses/>.

## Liability

Videre is a client for user-selected Invidious instances. Users are responsible for complying with laws and terms that apply to them.

This notice does not add restrictions beyond the GNU Affero General Public License.

You may view the LICENSE in which this software is provided to you [here](./LICENSE).

> 16. Limitation of Liability.
>
> IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
> WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS
> THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY
> GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE
> USE OR INABILITY TO USE THE PROGRAM (INCLUDING BUT NOT LIMITED TO LOSS OF
> DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD
> PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER PROGRAMS),
> EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
> SUCH DAMAGES.
