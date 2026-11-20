# Music in Videre

Music uses the selected Invidious instance for browsing, YouTube artwork, and playback
metadata, together with Videre's queues, local library, and download engine.
Opening Music does not contact `music.youtube.com`. It does not sign in to a
Google account or synchronize a Google library.

Music has its own **Home**, **Search**, and **Library** destinations. On a
phone, open **Music** from the main navigation. While Music is selected, the
bottom **Search** button opens Music Search and focuses its search field.
From a video tab the same button opens video search. Music Search finds songs,
channels, and public playlists through the selected Invidious instance.

To move **Music** or **Search** in the main phone navigation, open **Settings →
Browsing → Customize app sections**. You can also choose Music as your startup tab.
To change the buttons inside Music, open **Customize Music layout** in Browsing
settings. Reorder **Home**, **Search**, and **Library**, and choose which Music
Home shortcuts appear and in what order. Each profile keeps its own layout.
On TV, open the same editor from **Settings** and use a button’s menu to move
it earlier or later with the remote.

Paste a song, artist channel, or public Music playlist link from a saved
Invidious instance into Music Search to open it in Music. A timestamped watch
link starts at that position. Video Search opens the same links in Videos.
For a recognized content ID on an unfamiliar host, choose **Open on current
instance** to open it through your selected server, or **Search as text** to
search for the address.

## Home and Search

**Home** shows saved music, listening history, and recommendations. While Music
Home is open, Videre asks your selected Invidious instance for Discover songs
and prepares selections for saved artists and genres. The **Discover music**
shortcut appears when it can take you to songs. Artist and genre choices
appear as their tracks become available. Select one to see its prepared list.

While Music Home is visible, it also checks the first page of your regional
chart, or the worldwide chart where no regional playlist is available. It
checks one releases page for each of up to three saved artists. **From your
regional chart** and **Releases from saved artists** appear when the instance
returns usable results. Select a release to open its playlist. **Refresh**
reloads the shelves through the selected instance and favors chart tracks
you have not recently seen in the current Music session. A failed refresh
keeps the previous results for the affected shelf.

Swipe horizontally in **Quick Picks** to move one column at a time. Tap **⋮**
on a song for **Play next**, **Add to queue**, and recommendation feedback such
as **More like this**. Holding a song also opens its actions.
Tapping a song in Quick Picks or Discover music opens **Now playing** while the
song loads. Press Back once to return to the same place in the list. On phones
and tablets the song continues in the mini player.

When your listening history suggests a **Daily mix**, Home looks up related
songs. A mix appears once it has at least four eligible tracks. Tap its cover
to see the track list, play an individual song, or choose **Play all**.

**Top charts** opens public Top 100 Songs and Music Videos playlists from
[YouTube Music Global Charts](https://www.youtube.com/channel/UCrKZcyOJVWnJ60zM1XWllNw)
for Worldwide and supported countries. The picker puts your browsing country
first when it has a chart. Selecting a chart loads the publisher's current
playlist through your Invidious instance using the
[standard playlist endpoint](https://docs.invidious.io/api/#get-apiv1playlistsplid).
Track counts and playback availability depend on the returned playlist and
instance.

Under **Explore by saved artist**, choosing an artist switches to songs already
found for that artist. The artist search skips songs already saved to your
profile. Discovery checks each candidate's detailed metadata and only shows
videos categorized as Music.
Live, upcoming, missing-category, and unrelated results are excluded. This uses
the instance's upload categories; it cannot independently verify the audio or
correct an uploader's inaccurate category. Explicit Search skips this category
check.

General Discover and each of up to three saved-artist selections inspect at
most eight unique candidates and return up to six tracks. Explore checks up to
four candidates per genre for Pop, Jazz, Classical, and Electronic. Opening a
ready genre shows the verified songs and playback controls immediately.
Discovery does not download media, poll in the background, or keep searching
until the shelf is full. Existing bounded same-route metadata retries can add
requests when the instance fails. On onion or SOCKS connections, candidate checks
run one at a time. Other connections check at most two candidates concurrently.
An instance cooldown stops further checks and keeps tracks already verified.
Press **Refresh** for another selection or **Retry** after a connection failure.
Session changes discard old results. An unavailable instance never causes a
direct catalog fallback.
Discovery uses the instance's original titles and artwork without optional
DeArrow enrichment or related-video lookups. Your content filters apply to both
search candidates and verified details; editing those manual filters invalidates
the shelf.

Under **Settings → Browsing → AI content filters**, choose **Off**, **Label**,
or **Hide** for AiSList block entries, AiSList warnings, and the separate AI
music list. When adding a first Invidious instance, setup preselects **Hide** for
AiSList block entries and **Label** for warnings. You can choose either rule's
action before continuing. The separate AI music list starts off. AiSList
applies to YouTube browsing and Music songs. The AI music list applies to song
search and discovery in Music.
Videre matches the uploader ID or available channel handle locally. Music can
miss credited artists whose tracks appear under another uploader, and upstream
lists can contain mistakes. Use **Show hidden** to reveal filtered results for
the current list, or **Allow this channel** in the match label to save an
exception for that source and profile. Saved music, playlists, history, and
downloads remain accessible.

Videre checks enabled lists automatically on launch and when you return to the
app, usually about once a day. Enabling a rule also checks the list if it has
no verified copy or is due for an update. Videre downloads a snapshot on first
use and when a newer version is available. If a check fails or you are offline,
it keeps using the last verified list. Routine list changes arrive through
Flow's daily mirror without a Videre update.

[Flow](https://github.com/Flow-Tube/AIlist) publishes signed snapshots of
[AiSList](https://github.com/Override92/AiSList) under
[CC BY-NC 4.0](https://github.com/Override92/AiSList/blob/main/LICENSE) and a
converted music list made from [Soul Over AI](https://github.com/xoundbyte/soul-over-ai)
([CC BY 4.0](https://github.com/xoundbyte/soul-over-ai/blob/main/LICENSE.md)) and
[Spotify AI Blocker](https://github.com/CennoxX/spotify-ai-blocker)
([MIT, © 2026 CennoxX](https://github.com/CennoxX/spotify-ai-blocker/blob/main/LICENSE)).
Flow combines and converts the music sources to YouTube channel IDs.

Home does not load the instance's trending feed. Current Invidious versions route
the former `type=Music` trending request to general livestreams, which caused
unrelated videos to appear as music in [issue #33](https://github.com/DVBeckwitt/Videre/issues/33).
The production music catalog therefore treats that feed as unsupported instead
of relabeling the response or falling back to another service. See the
[Invidious trending implementation](https://github.com/iv-org/invidious/blob/9f0b4c89f7a564c1e34ac00cca6cb8ae8f5bd7c9/src/invidious/feeds/trending.cr).
The existing browsing-country setting applies to Search and discovery.

## Browse and listen

Search **Songs**, **Channels**, or **Playlists** through Invidious. Songs use
the server's video search; Channels use channel search and show that channel's
popular uploads. When the selected instance offers release playlists for the
channel, the artist page shows **Releases** above the uploads. Select a release
to open its public playlist. Channel and instance coverage vary. Public
playlists retain the server's track order. Selecting a song starts from the beginning; **Resume listening**
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
per-video resume position as Videos. Each profile keeps separate Music and
Video histories. Open **Music → Library → Music history** to see what you
played from Music. Playing a video in audio-only mode keeps it in Video
history. A recording played from both sections appears in both lists. Removing
it from one list preserves its entry in the other and its resume position.

For the original purple colors, choose **Settings → Appearance → Color palette
→ Classic purple**. The choice also applies to the Music player.

In the expanded Music player, tap a linked artist name to open that artist’s
Music page while the song continues. Songs with only an artist name display it
as plain text.

When a song has a matching music video, tap **Video** beside **Lyrics** to
watch it in the artwork area. Tap **Cover** to switch back. Both views share
the song’s audio, playback position and queue. Videre can use the playing
upload itself or find an official video for the same recording on your
selected instance. Local songs and audio-only downloads keep their artwork.

Swipe the artwork or mini player to move to an adjacent song in the queue.
While a song plays, Videre prepares the next and previous songs and buffers
their opening audio. With queue autoplay enabled, the next song uses the same
buffer when the current song ends. If you swipe before a song is ready, the
player shows your selection while loading finishes.

With the phone locked, queue autoplay follows the same order and song
transition settings. Use the lock-screen media controls to pause, resume
or skip a song.

For rewinding within a song on Android, the audio player keeps up to 90 seconds
of recently played audio in memory. The available window can be shorter for
high-bitrate tracks. Seeking further back uses the normal playback source.

Under **Settings → YT Music → Song transition options**, choose how queued
songs change automatically for your profile. **Seamless** is the default and
starts the next song as soon as it is ready. **Pause between songs** inserts
silence. **Fade out then in** lowers the ending song’s volume, then raises the
next song’s volume from silence. **Crossfade** plays both songs together as the
first fades out and the next fades in. For any timed mode, **Transition duration**
can be set from 1 to 10 seconds and defaults to 3 seconds. Fades shorten for
very short songs. Crossfade begins once the next song has buffered. Tapping
Next or swiping still skips immediately.

Music playback keeps song titles, artists, albums, and artwork in the player,
queue, local playlists, offline downloads, and Android media notification.
Shuffle, repeat, seeking, playback speed, and the sleep timer reuse the existing
player. The audio decoder remains mounted when the artwork player is minimized
or expanded. TV uses focusable audio controls with the same playback engine.

Turn on **Settings → Video player → Remember playback speed and pitch** to keep
separate values for Music and video in your profile. In Music, open **Sound**
to adjust either value or use the Android equalizer.
**Bass boost** and **Treble boost** adjust the appropriate
device bands; individual frequency sliders use the device's actual gain range.
**Reset equalizer** returns the bands to flat and disables the effect. The
equalizer starts disabled, applies only to Music's current audio session, and
resets when playback closes or accounts change. It does not change system-wide
audio settings or edit downloaded files. Devices without a working equalizer
show an unavailable state while speed, pitch and playback remain usable.

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

When signed in, choose **Save a copy on server** on a fully loaded playlist to
create a private copy in the selected Invidious account. After **Saved on
server** appears, open the app’s main **Playlists** list and look for the
copy labeled **On your server**.

If Invidious returns HTTP 500 while adding a song, Videre checks which songs
it already saved and resumes once automatically. If the song still fails,
Videre shows its name and position. **Resume server copy** continues from the
saved entries in that same playlist.
If you deleted the previous server copy, choose **Create a new copy** to
replace it. If the server did not confirm creation, check the server playlist
list before choosing that action.

Library backups include these saved items. **Merge** combines Music bookmarks
and local-playlist markers, keeping the existing copy of a duplicate. **Replace**
replaces the included local data. An import exceeding the combined Music library
limits fails without partially changing the destination library.

**Download audio** queues songs through Videre's existing download manager on
phones and tablets. Downloaded Music retains its labels and can play offline.
Library's Downloads filter shows Music downloads for the active profile, with
progress, pause, resume, and retry controls. Select a completed download to play
it offline.
The Wi-Fi preference, retry, and profile ownership rules apply. TV does not
offer downloads.

Music downloads select the highest available compatible audio bitrate by default.
Under **Settings → YT Music**, choose **MP3** (the default), **Opus (Best quality)**,
or **M4A (AAC)** for the saved file. Opus preserves an Opus source in an Ogg file.
M4A preserves an AAC source. Videre writes the available song title, artist
and album into the file. The output format applies to new downloads and explicit
exports.

On Android 10 and later, the default Music destination is **Music/Videre**.
Select this folder in another player to discover the songs. On Android 7–9,
choose a shared folder when prompted. Under **Settings → Download folders**,
**Audio downloads** can use private app storage or a chosen folder independently
of **Video downloads**. Changes apply to new downloads. To share an existing
private song, open **Downloads** and choose **Export a copy of this song**.

**Music → Library → On this device** plays audio already on your device.
Local playback starts off. **Choose a folder** grants access to that folder and
its subfolders. **Use Android music library** asks for audio permission and
shows files indexed by Android. The selected source is available across Videre
profiles. Videre keeps a device-local index and loads tags and artwork in the
background. You can play songs while the library updates.

Use **Sort** to choose the field and direction. When Android cannot provide
the date a file was added, Videre uses the date it first discovered the file.
The song menu offers **Rename file** for supported files, with an Android write
prompt when required. This changes the filename and preserves embedded tags.
Forgetting the library leaves your audio files in place.

Tap a song to play the displayed list from that song. **Play next** inserts
the song after the current track and **Add to queue** appends it. Either action
starts a local queue if you're listening to nothing. Videre asks before
replacing an active queue from another source. In **Queue**, you can drag tracks
above or below the playing song, or choose **Move up** or **Move down**. You can add the
same file more than once. The queue, speed and pitch controls work offline.

## Google Takeout import

Use the import button in **Music → Library**, or **Settings → Import Google
Takeout**, to choose a ZIP or UTF-8 CSV saved in this device's Downloads/storage.
The picker accepts on-device Android document providers; save files from cloud
storage to the device first. The import reads IDs and labels from the local
file without contacting Google or your Invidious instance.

The preview lists recognized song collections. Choose the wanted collection and
select **Import songs** to merge it into **Library → Songs** in the current
profile. Existing songs and their metadata are kept; new songs retain file order.
Canceling changes nothing. Reimporting does not add duplicates. Invalid IDs and
duplicate rows are counted in the preview, and an empty collection cannot be
imported. Capacity errors leave the existing library unchanged.

Supported exports include `music-library-songs.csv`, playlist video CSVs, and
older playlist CSVs with a metadata header. A general Music library export can
include saved songs you have not liked; a Liked videos export can include
non-music videos. These are labeled separately from Liked Music. When a ZIP
contains both song metadata and playlist IDs, missing labels are filled only
from matching IDs in that same local export. Remaining missing titles initially
use the song ID. The import saves references to songs. Playback uses your
selected Invidious instance.

To fill missing titles, artist labels, and durations, open **Music → Library →
Songs → Load song details**. This also works on songs you imported previously.
Videre sends their video IDs to your selected Invidious instance one at a time
and fills gaps with the available upload details. It keeps the
details already saved. You can stop the lookup and keep details already saved
by it. Private, deleted, or unavailable uploads may still show their IDs.

ZIPs are limited to 64 MiB, individual CSVs to 10 MiB, and archive CSV data to
16 MiB total. Only relevant CSVs are read from a full Takeout archive; media
files are not extracted. For larger exports, extract the wanted CSV yourself
and select it. The existing Music library limit remains 10,000 entries and
5 MiB of metadata, including previously saved entries. Export formats or data
that Google does not include cannot be reconstructed by this local importer.

## Audio quality, artwork, and lyrics

**Settings → YT Music → Streaming audio quality** sets the active profile's
preference for new Music streams. **Auto** uses Videre's normal source order.
**Data saver** prefers the lowest advertised bitrate in the selected audio
language, and **Highest available** prefers the highest. In Music Now Playing,
**Audio quality** lists the renditions available from your selected Invidious
instance. Choose a rendition for the playing song or select **Use profile
default**. Downloaded audio has the quality it was saved with.

**Settings → YT Music → Cover corners** chooses **Rounded** or **Square** for
the cover in expanded Music Now Playing in the active profile.

By default, Music displays a saved cover or an identifiable YouTube Art Track
image through the selected Invidious instance. Ordinary uploads can show their
Invidious-proxied video thumbnail. The music-note placeholder appears when
there is no usable image.

**Settings → YT Music** has a separate opt-in for MusicBrainz and Cover Art
Archive. When enabled, opening Music Now Playing sends the song title, artist,
and available album and duration to MusicBrainz. For a confidently matched
release, Videre loads the front cover from Cover Art Archive and the Internet
Archive. It reuses the local result on Music screens in that profile. Closing
Now Playing stops queued lookups and drops late results. Turning the option off
returns Music to the Invidious artwork. The configured Videre proxy applies to
both providers.
[MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API) · [Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive/API)

Expand Music Now Playing and tap **Lyrics** on the cover artwork to look up
synced or plain lyrics from LRCLIB. The first lookup asks you to enable the
provider. The same switch is available in **Settings → YT Music**. Videre sends
the song's title, artist, and known album and duration when you open the panel.
The Videre network proxy applies when enabled. The active timed line is
highlighted and follows playback. Scroll manually to read ahead or behind,
then select **Follow lyrics** to resume following. With animations off, the
highlight and position update immediately. Select a timed line to seek when
playback supports it. Coverage depends on the recording match and LRCLIB's
catalog.
[LRCLIB API](https://lrclib.net/docs.txt)

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

Music searches, channel details, public playlists, and song metadata
use the selected server's standard Invidious API through the existing request
and authentication layer. NerdVPN API-key access and protected-server gateway
sessions follow the same rules as Videos. Missing access or a failed request
does not switch to YouTube Music. Responses and playlist pagination are rejected
after a profile, account, backend, server, or proxy change.

YouTube Music artwork uses the Invidious image proxy. Music discovery, playback,
downloads, and notifications can use the selected instance for these images.
Community cover lookups have their own consent and use a local cache for Music
screens. Music notifications use stock or already saved download artwork.
Optional SponsorBlock playback support retains its separate setting.

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

Android acceptance should cover Music search and local Home on both configured
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
