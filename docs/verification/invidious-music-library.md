# Invidious-only Music browsing and library

This implements the request to remove YouTube Music-exclusive catalogs and
make Music useful through Invidious search and local playlists. It preserves
the existing privacy, playback recovery, and saved-account changes. No commit,
push, merge, or release is part of this work.

## Behavior

- Phone, tablet, and TV Music navigation is **Home / Search / Library**.
  Home shows the full Music trending feed supplied by the selected instance,
  with Search and Library shortcuts that remain available if trending fails.
- Search supports **Songs / Channels / Playlists** through standard Invidious.
  Song search uses video search; channel pages show popular uploads. Public
  playlists and supported `RD` mixes keep their existing bounded loading and
  playback behavior. `OLAK5uy_` public playlist IDs remain supported.
- Album, new-release, chart, and mood browsing, their capability flag, and
  their client methods have been removed from the production catalog. The
  contract contains only seven supported Invidious operations. Obsolete catalog
  notices and `MPRE` album navigation have also been removed. Incoming supported
  Music links remain local identifiers; Videre does not fetch the official URL.
- Library offers local/public playlists, saved songs, channels, and phone/tablet
  downloads. Local playlists support creation, adding songs, playback, resume,
  and **Remove from playlist** within Music. Removal uses the original playlist
  and video identity, preserving other entries and independent saved-song
  bookmarks. Account/profile changes invalidate pending actions.
- Existing local playlists, downloads, song metadata, and backups are preserved.
  Legacy album bookmarks retain their serialized enum/data for import/export
  compatibility but are hidden from active browsing. Album labels attached to
  existing songs remain display metadata, without an album-catalog link.

Search state is retained when switching Music/Videos and cleared with the owning
profile/session as appropriate. An inactive embedded Search page does not capture
Back or keyboard focus. Playlist/channel Back navigation remains within Search
before leaving its route. The README and Music guide describe these supported
flows.

## Privacy and regression coverage

No new network client, host, redirect exception, or direct playback path was
added. The production adapter delegates to the selected-instance Service layer.
Historical direct-catalog parsers remain test-only; their exclusive contracts
and region exception are no longer production API. Optional existing third-party
services retain their own settings; this change does not claim that every app
network request is an Invidious request.

Focused checks passed before the full gate: 141 catalog/transport/authentication
tests, 49 library/action/persistence tests, 14 discovery tests, and 156 UI/deep-link
tests. These groups overlap and are not a distinct-test total. Strict scoped
analysis and formatting passed. Replaced tests covered retired catalog UI;
supported search, queue order, retry/cancellation, navigation, profile isolation,
local data preservation, and routing/privacy assertions remain covered.

Local evidence is under `build/music-invidious-only/` (ignored by Git).

The Music-only implementation passed the complete canonical validator: formatting,
configured application analysis, strict regression analysis, and **2,618 tests**,
with four opt-in live-service skips (`canonical-validation.log`). This result
predates the subsequently requested profile-deletion changes; the combined build
and device acceptance follow below.

## Combined Music and profile validation

The final combined implementation passed **2,661 tests**, with four opt-in live
skips, formatting, configured application analysis, and clean strict regression
analysis (`combined-canonical-validation-final.log`). Validation-helper,
Windows release-script safety, and ten APK-signing verifier checks also passed.
Profile-specific behavior and regression evidence are described in
[profile management](profile-management.md).

The normal `lib/main.dart` debug APK was freshly compiled after the temporary
Android lock fixture. Its packaged kernel matches that fresh compilation, and
the APK contains the native privacy/media guards. The production snapshot covers
741 files at fingerprint
`66ffa06eb7878c3a49ba6f307b821ac131c33c1d2c9581d427f20418505bfc07`.
The working tree is based on `40826fd6187977cd5c7a93f9a36627ef58c2e21d`;
the changes remain uncommitted.

Debug artifact: `build/music-invidious-only/app-debug-invidious-music.apk`.
SHA-256: `e218e7167684254b9a7279c713792dc23aa2b786e2d4acc683ee9f0f4562b927`.
Machine-readable source/build identity is in the adjacent `build-identity.json`.

Fresh profile builds passed for `armeabi-v7a`, `arm64-v8a`, and `x86_64`. Each
packaged AOT library matched its fresh compilation through merge/strip (including
ELF build identity), with the same native guards present. Their SHA-256 values:

- `armeabi-v7a`: `bf60d543444c26a38f8344264b880b3bc3c3d955da53dfe7fccc2dd3762514d1`
- `arm64-v8a`: `44c76df23ccbe48cdf7e40d3e613c6301a060de7c14b100a887b066a73d2b815`
- `x86_64`: `ae36d5bef93e8d25b8e011753ff7f0c640a46691836bc392ae7d29f36c9eead2`

`:videre_proxy:testDebugUnitTest` completed successfully with its unchanged
native test inputs up to date. The existing reports contain 100 tests across
12 suites, zero failures/errors; this command did not rerun those cached tests.
Linux-host CI and the full Nix/live integration suite were not run. No push or
release was performed.

## Android acceptance

The persistent `Videre_NerdVPN_Test` emulator retained its saved login across
install-in-place updates. The first-pass installed artifact (`aac5c42d…`, before
the Welcome-only repair) passed phone Home/Search/Library navigation, scrolling
the full trending grid, and populated NerdVPN Songs/Channels/Playlists searches.
Only a uniquely named local test playlist was created. Adding, removing, and
deleting it through the app passed, preserving the existing Watch Later and
standalone song bookmarks.

NerdVPN returned metadata successfully but the tested PSY stream produced native
HTTP 502 errors during automatic backend fallback. That bounded attempt was
stopped; it does not establish that every NerdVPN track or backend fails. The
same local playlist played through the existing DV account: native position
advanced, pause held at 18.408 seconds, and Resume playlist reopened ready and
playing at 18.588 seconds. The test playlist was then removed through the normal
Videos playlist UI. Evidence: `native/first-pass-partial.json` and sanitized
`native/initial-playback-statuses.json` under the local evidence directory.

On the Welcome-fixed `29e17e9e…` artifact (installed SHA-256 checked), actual Android
D-pad/Select opened Music Search and Library from the TV sidebar. The search
filters were Songs/Channels/Playlists, with no Albums destination. Phone and TV
profile create/rename/delete and Welcome access passed as recorded in
[profile management](profile-management.md). Existing accounts and libraries
were preserved; temporary profiles were removed and phone layout restored.

A bounded NerdVPN check on that APK searched for the original reported
`tV5UilNUYRY` video in Music and opened it once. The proxied itag 251 stream was
ready/playing with no native error; position advanced from 19.028 to 21.916
seconds. It was then paused and closed. NerdVPN playback therefore succeeded for
this track on that build; the earlier PSY 502 remains an observed failure
for that track/attempt, rather than evidence of a general NerdVPN outage.

The emulator was left with the original Default profile, NerdVPN selected,
phone layout, no active playback, and the saved NerdVPN/DV accounts intact.
This pass does not establish live onion availability or physical-device/OEM
screen-off behavior; those acceptance limits remain separate from the Music
and profile changes.
