# Music in Videre

Music uses public YouTube Music catalog data and Videre's existing Invidious
playback, queues, local library, and download engine. It does not sign in to a
Google account or synchronize a Google library.

Use the **Videos / Music** switch at the top of the home screen on phones,
tablets, and TVs. Music has its own **Home**, **Explore**, and **Library**
destinations. Use the search button in Music to find a specific song, album,
artist, or public playlist.

Choose **Settings → Browsing → Home experience** to show **Videos and Music**
(the default), **Videos only**, or **Music only**. The same choice is available
in the home and navigation customizers. A single-mode choice opens that home
directly and hides the switch. The preference and last selected mode belong to
the active Videre profile.

## Home and Explore

**Home** shows public new albums and singles, global chart playlists, and mood
and genre shortcuts. **Explore** provides the full new-release grid, charts
with a country selector, and the public moods and genres. Selecting a mood or
genre opens its curated playlists.

Discovery uses anonymous public catalog feeds. New releases come from the
catalog's release grid. Chart playlists retain their supplied titles, such as
daily or weekly video charts, and availability varies by country. Artist cards
are shown as **Artists in the charts**, without assigning numerical ranks. The
country selector lists the regions supported by the catalog.

Personalized **For you** groups are excluded. Videre does not provide Google
account recommendations, synchronized likes, or a synchronized YouTube Music
library. Your local Library is separate from these public feeds.

## Browse and listen

Search songs, albums, artists, or public playlists. Artist pages show popular
songs, albums, and singles/EPs. Album and playlist pages retain the catalog's
track order. Selecting a song starts from the beginning; **Resume listening**
continues the saved Music session at its saved position.

Selecting a track in a public or local playlist keeps the full playlist in the
queue, including earlier tracks and repeated occurrences. **Resume playlist**
returns to that playlist's last occurrence and exact timestamp, independently
of the most recently opened Music session. Progress indicators use the same
per-video history as Videos; marking a recording watched does not discard its
precise timestamp. Playlist progress belongs to the active Videre profile.

Music playback keeps song titles, artists, albums, and artwork in the player,
queue, local playlists, offline downloads, and Android media notification.
Shuffle, repeat, seeking, playback speed, and the sleep timer reuse the existing
player. The audio decoder remains mounted when the artwork player is minimized
or expanded. TV uses focusable audio controls with the same playback engine.

## Local library and downloads

**Library** has filters for **Playlists**, **Songs**, **Albums**, **Artists**,
and, on phones and tablets, **Downloads**. Use **Save song**, **Save album**,
**Save artist**, or **Save playlist** to bookmark catalog items in the active
Videre profile. Saved albums, artists, and public playlists reopen their catalog
pages; bookmarks do not download audio. You can remove a bookmark from Library
or its catalog page.

Use **Save to playlist** on a song or collection to choose or create a playlist
on this device. Collections are added in order; existing songs are not duplicated.
Library's Playlists filter includes these local Music playlists and bookmarked
public playlists. Local playlist pages show their Music tracks and provide
**Play all** and collection actions.
These operations belong to the active Videre profile. Switching profiles closes
an open save dialog and stops any remaining collection operation.

Library backups include these saved items. **Merge** combines Music bookmarks
and local-playlist markers, keeping the existing copy of a duplicate. **Replace**
replaces the included local data. An import exceeding the combined Music library
limits fails without partially changing the destination library.

**Download audio** queues songs through Videre's existing download manager on
phones and tablets. Downloaded Music retains its labels and can play offline.
Library's Downloads filter shows Music downloads for the active profile, with
progress, pause, resume, and retry controls. Select a completed download to play
it offline.
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

Public discovery feeds, catalog searches, and artist, album, or playlist lookups
contact `music.youtube.com` through Videre's configured network transport, including
SOCKS5/Orbot. These requests do not send Invidious credentials or Google login
cookies. Playback URLs are resolved by the selected Invidious backend and follow
the media-proxy setting. Music catalog artwork loads from its original public
image URLs through the same configured network transport, without Invidious
credentials or Google login cookies. Album, artist, playlist, player, download,
and notification covers therefore do not depend on the Invidious image proxy.
Fallback video thumbnails still use the selected instance's image routing,
including saved songs without a catalog cover. New Music history entries retain
their catalog artwork and song metadata.

The two proxy controls are independent and can be combined:

| Network proxy (SOCKS5/Orbot) | Proxy videos | Catalog and artwork | Audio streams |
|---|---|---|---|
| Off | Off | Public catalog/image hosts | Media host supplied by Invidious |
| Off | On | Public catalog/image hosts | Through Invidious |
| On | Off | Through SOCKS | Media host through SOCKS |
| On | On | Through SOCKS | Invidious through SOCKS |

**Proxy videos** is an Invidious media setting, not a general Internet proxy.
Invidious's [standard API](https://docs.invidious.io/api/) does not provide the YouTube Music discovery/catalog
endpoints. Enable **Settings → Network proxy** to route those requests through
SOCKS or Tor as well. An enabled but unavailable SOCKS endpoint fails rather
than trying a direct connection. Changing the network proxy discards the cached
catalog visitor data; unfinished responses from the previous route cannot seed
requests on the new route. Multi-page collections and discovery lookups also
discard continuations from the previous route. Retry a Music section after
changing the route.

If the anonymous startup request redirects to YouTube's HTTPS consent page,
Videre retries the original Music URL once with `SOCS=CAE=`, the
[reject-optional-cookies value documented by NewPipe](https://github.com/TeamNewPipe/NewPipeExtractor/blob/39b9482ea2be0e9ab95a31987c2f3347396e84ec/extractor/src/main/java/org/schabi/newpipe/extractor/services/youtube/YoutubeParsingHelper.java).
It does not follow the redirect, import response cookies, or retain this marker
for API requests or artwork. The retry shares the original route and deadline.

The catalog can be unavailable in a Tor exit's country. Music identifies the
observed regional startup page and suggests another circuit or region; it does
not switch to a direct connection. Proxied catalog requests allow up to 60
seconds per request (20 seconds without SOCKS), while transport connection
deadlines still apply. Invidious availability is separate from catalog access.
An earlier live Tor check returned the regional startup page after this consent
retry; it established accurate regional error handling, not catalog availability
from that exit.

YouTube Music catalog endpoints are unofficial. Their response formats are
isolated in `MusicCatalogService` and its parsers, with offline fixtures and an
opt-in live smoke test. Artist release shelves follow the catalog's full-list
links and continuations, rather than treating preview cards as the entire list.
Discovery validates country/category inputs and bounds continuation requests;
unavailable or malformed responses produce a retryable error instead of a
substitute feed.
See the [upstream browsing reference](https://ytmusicapi.readthedocs.io/en/stable/reference/browsing.html).

## Verification

A bounded rerun late on November 9, 2026 (November 10 UTC) used separate US and
DE exit constraints. Tor's check API confirmed both routes; Tor's local GeoIP
data reported the selected countries, which does not establish Google's own IP
classification. All four live catalog/discovery cases on the US route failed
with the known regional response. One exact startup probe on the DE route also
returned that page without catalog configuration, so the full suite was not
repeated there. These negative checks preserve the earlier successful Tor
observations; they do not establish current catalog availability or fresh Music
playback on either tested route.

The canonical `tools/validate.dart` checks include the offline `test/music`
suite alongside the existing player, download, profile, and video regressions.
The live catalog and anonymous discovery checks are deliberately separate:

```powershell
./submodules/flutter/bin/flutter.bat test --dart-define=VIDERE_LIVE_MUSIC_TEST=true test/music/catalog_live_test.dart
```

To repeat both media-proxy modes through a running SOCKS listener, add
`--dart-define=VIDERE_LIVE_MUSIC_SOCKS_PORT=9050`. The optional
`VIDERE_LIVE_MUSIC_SOCKS_HOST` define defaults to `127.0.0.1`.
`--dart-define=VIDERE_LIVE_MUSIC_VERIFY_TOR=true` also requires Tor's check API
to confirm the route, without printing its IP address. The live checks stay
disabled unless `VIDERE_LIVE_MUSIC_TEST=true` is explicitly supplied.

Android acceptance should cover the Videos/Music switch, Home experience choices,
Home/Explore/Library navigation, country and mood selection, public catalog
browsing, both media-proxy modes, screen-off playback, queue changes,
interruption handling, local saving, offline playback, session restoration,
and TV D-pad access. A Windows APK build or widget test does not establish
physical-device or Linux CI coverage.

Gapless playback and Google-account synchronization are outside this anonymous
Music implementation.
