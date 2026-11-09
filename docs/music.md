# Music in Videre

Music uses public YouTube Music catalog data and Videre's existing Invidious
playback, queues, local library, and download engine. It does not sign in to a
Google account or synchronize a Google library.

Open **More shortcuts → Music** on a phone, or the Music button on a tablet or
TV. Custom phone navigation layouts can place Music in the bottom or top area.

## Browse and listen

Search songs, albums, artists, or public playlists. Artist pages show popular
songs, albums, and singles/EPs. Album and playlist pages retain the catalog's
track order. Selecting a song starts from the beginning; **Resume listening**
continues the saved Music session at its saved position.

Music playback keeps song titles, artists, albums, and artwork in the player,
queue, local playlists, offline downloads, and Android media notification.
Shuffle, repeat, seeking, playback speed, and the sleep timer reuse the existing
player. The audio decoder remains mounted when the artwork player is minimized
or expanded. TV uses focusable audio controls with the same playback engine.

## Local library and downloads

Use **Save to playlist** on a song or collection to choose or create a playlist
on this device. Collections are added in order; existing songs are not duplicated.
These operations belong to the active Videre profile. Switching profiles closes
an open save dialog and stops any remaining collection operation.

**Download audio** queues songs through Videre's existing download manager on
phones and tablets. Downloaded Music retains its labels and can play offline.
The existing download folder, Wi-Fi preference, retry, and profile ownership
rules apply. TV does not offer downloads.

## Ads and SponsorBlock

Music plays the media streams supplied by Invidious, using Videre's native
player. It does not use the YouTube Music website's advertising player.

SponsorBlock separately skips community-marked sections within a recording.
The existing **Settings → Video player → SponsorBlock** choices also apply to
Music. Paid sponsor segments and **Music: Non-Music Section** are enabled by
default unless you have disabled them. Other categories remain optional.
Music shows a brief **Sponsor skipped** notice after a skip.
Category changes take effect when a track is loaded again. Unknown songs or
unavailable SponsorBlock data play normally.

New Music downloads save available segment data for the categories enabled at
download time. Offline playback applies your current choices to that saved data,
without a network request. Previously downloaded songs need to be downloaded
again to acquire segment data, including any category enabled after downloading.

## Network boundary

Catalog searches and artist, album, or playlist lookups contact
`music.youtube.com` through Videre's configured network transport, including
SOCKS5/Orbot. These requests do not send Invidious credentials or Google login
cookies. Playback URLs are resolved by the selected Invidious backend and follow
the media-proxy setting. Artwork uses Videre's existing image routing.

YouTube Music catalog endpoints are unofficial. Their response formats are
isolated in `MusicCatalogService` and its parser, with offline fixtures and an
opt-in live smoke test. Artist release shelves follow the catalog's full-list
links and continuations, rather than treating preview cards as the entire list.
See the [upstream browsing reference](https://ytmusicapi.readthedocs.io/en/stable/reference/browsing.html).

## Verification

The canonical `tools/validate.dart` checks include the offline `test/music`
suite alongside the existing player, download, profile, and video regressions.
The live catalog check is deliberately separate:

```powershell
./submodules/flutter/bin/flutter.bat test --dart-define=VIDERE_LIVE_MUSIC_TEST=true test/music/catalog_live_test.dart
```

Android acceptance also checks public catalog browsing, both media-proxy modes,
screen-off playback, queue changes, interruption handling, local saving,
offline playback, session restoration, and TV D-pad access. A Windows APK build
or widget test does not establish physical-device or Linux CI coverage.

Gapless playback and Google-account synchronization are outside this anonymous
Music implementation.
