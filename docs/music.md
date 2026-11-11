# Music in Videre

Music uses the selected Invidious instance for browsing, artwork, and playback
metadata, together with Videre's queues, local library, and download engine.
Opening Music does not contact `music.youtube.com`. It does not sign in to a
Google account or synchronize a Google library.

Use the **Videos / Music** switch at the top of the home screen on phones,
tablets, and TVs. Music has its own **Home**, **Search**, and **Library**
destinations. Search finds songs, channels, and public playlists through the
selected Invidious instance.

Choose **Settings → Browsing → Home experience** to show **Videos and Music**
(the default), **Videos only**, or **Music only**. The same choice is available
in the home and navigation customizers. A single-mode choice opens that home
directly and hides the switch. The preference and last selected mode belong to
the active Videre profile.

## Home and Search

**Home** shows the full **Trending music** feed returned by the server's standard
`/api/v1/trending?type=Music` endpoint, with shortcuts to **Search** and **Library**.
The existing browsing-country setting applies. Search and Library remain
available when the instance's trending feed is empty or fails; there is no
fallback to Google.

Music provides Invidious search, channels, public playlists, and local playlists.
YouTube Music's album, new-release, chart, and mood catalogs have no browsing
pages or API routes in the app. Personalized Google recommendations and
synchronized likes are not part of Music.

## Browse and listen

Search **Songs**, **Channels**, or **Playlists** through Invidious. Songs use
the server's video search; Channels use channel search and show that channel's
popular uploads. These are standard YouTube results supplied by Invidious, not
a verified YouTube Music artist or album catalog. Public playlists retain the
server's track order. Selecting a song starts from the beginning; **Resume listening**
continues the saved Music session at its saved position.

Public playlists, including `OLAK5uy_` IDs, use Invidious's standard playlist
endpoint. Saved mixes with `RD` IDs use its standard mixes endpoint.
A dynamic mix plays the batch returned by that endpoint;
it does not claim to load an endless radio stream. Public playlist pagination
merges overlapping pages by source position while retaining repeated recordings
at different positions.

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

**Library** has filters for **Playlists**, **Songs**, **Channels**, and, on phones
and tablets, **Downloads**. Use **Save song**, **Save channel**, or **Save playlist**
to bookmark items in the active Videre profile. Bookmarks do not download audio.
You can remove a bookmark from Library or its detail page.

Album bookmarks from earlier versions remain stored and included in backups for
import/export compatibility, but are hidden from the active library. Their
YouTube Music album browse IDs are not opened. Existing local playlists,
downloads, saved playback, and album labels attached to songs are preserved.

Use **Save to playlist** on a song or collection to choose or create a playlist
on this device. Collections are added in order; existing songs are not duplicated.
Library's Playlists filter includes these local Music playlists and bookmarked
public playlists. Local playlist pages show their Music tracks and provide
**Play all**, **Resume playlist**, and collection actions. Use **Remove from
playlist** in a song's Music actions to remove it from that local playlist.
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

Music searches, trending, channel details, public playlists, and song metadata
use the selected server's standard Invidious API through the existing request
and authentication layer. NerdVPN API-key access and protected-server gateway
sessions follow the same rules as Videos. Missing access or a failed request
does not switch to YouTube Music. Responses and playlist pagination are rejected
after a profile, account, backend, server, or proxy change.

Google-hosted Music artwork, including saved catalog covers from earlier
versions, uses the Invidious image proxy. Player, library, video cards, downloads,
and notification artwork follow the same routing, without a direct Google
fallback. Existing optional third-party services such as SponsorBlock and
DeArrow retain their own settings and network routes.

Video, audio, and downloads always use the selected Invidious media proxy.
The direct-playback switch has been removed. Previous `use-proxy=false` settings
and imported backups cannot restore direct Google playback. App transport rejects
official YouTube destinations, including redirects and adaptive stream children,
before opening their connections. If an instance cannot proxy a stream, playback
fails instead of connecting directly to Google. Unsupported Google image paths
show a placeholder or another proxied image, without a direct fallback.

Invidious fetches content from YouTube on its server; this keeps those connections
off the device, rather than removing YouTube from the server's upstream sources.
See the [Invidious API](https://docs.invidious.io/api/) for the standard browsing
and video metadata endpoints used by Music.

The optional **Settings → Network proxy** routes the Invidious connection and
other enabled services through SOCKS or Tor. It does not enable direct YouTube
playback. An unavailable SOCKS endpoint fails without trying a direct connection.

## Verification

The canonical `tools/validate.dart` checks include the offline `test/music`
suite alongside player, download, profile, and video regressions. The Invidious
adapter tests exercise both NerdVPN and `invidious.dvbeckwitt.duckdns.org` origins with
mocked transport, standard API paths and authentication routing, complete
playlist pagination, and rejection of stale results. UI tests cover Home and
search, local library actions, hidden legacy album bookmarks, and artwork proxying.
Mocked endpoints do not establish live server availability or Android playback.

Android acceptance should cover Music search and trending on both configured
servers, authenticated artwork, playlist queues, screen-off playback, local
saving, offline playback, session restoration, and TV D-pad access. A Windows
APK build or widget test does not establish physical-device or Linux CI coverage.

### Historical direct-catalog checks

These observations describe the earlier direct YouTube Music implementation,
which the application's default Invidious adapter no longer calls. They are not
evidence for current Invidious music behavior.

A bounded rerun late on November 9, 2026 (November 10 UTC) used separate US and
DE exit constraints. Tor's check API confirmed both routes; Tor's local GeoIP
data reported the selected countries, which does not establish Google's own IP
classification. All four live catalog/discovery cases on the US route failed
with the known regional response. One exact startup probe on the DE route also
returned that page without catalog configuration, so the full suite was not
repeated there. These negative checks preserve the earlier successful Tor
observations; they do not establish current catalog availability or fresh Music
playback on either tested route.

The earlier direct-catalog implementation and parser fixtures are now isolated
under `test/music/support/` for offline historical regression evidence. They are
not included in the app. There is no direct-catalog fallback or opt-in mode.

The opt-in live check now exercises only an explicitly supplied Invidious server:

```powershell
./submodules/flutter/bin/flutter.bat test --dart-define=VIDERE_LIVE_MUSIC_TEST=true --dart-define=VIDERE_LIVE_MUSIC_INSTANCE=https://your-invidious-instance test/music/catalog_live_test.dart
```

The instance must allow the test client's API access. Credentials are not accepted
in command-line defines. To exercise a running SOCKS listener, add
`--dart-define=VIDERE_LIVE_MUSIC_SOCKS_PORT=9050`; the optional
`VIDERE_LIVE_MUSIC_SOCKS_HOST` defaults to `127.0.0.1`.
`--dart-define=VIDERE_LIVE_MUSIC_VERIFY_TOR=true` additionally checks Tor's API
without printing an IP address. Live checks remain disabled without the explicit
opt-in, and reject official YouTube addresses or off-origin redirects.

Gapless playback and Google-account synchronization are outside this Music
implementation.
