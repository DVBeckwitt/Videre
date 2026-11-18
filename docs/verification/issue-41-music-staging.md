# Issue 41 Music verification

Videre uses stock Invidious for YouTube browsing, playback, and artwork.
Optional Lyrics and community covers have independent per-profile consent.
The initial extension experiment was retired before any server configuration
was activated.

- Offline tests cover stock Music catalog routing, same-instance media and
  images, and request rechecks after account or proxy changes. A loopback SOCKS
  server verifies both provider routes.
- Existing saved artwork and downloads are preserved. Fixtures cover playlist
  artwork, hydrated queue artwork, a failed HD thumbnail followed by a
  working smaller rendition, and recovery from a damaged cached cover.
- The persistent Android test emulator played downloaded audio and responded
  to background media Pause. It displayed stock artwork with both opt-ins off
  and exposed separate switches under **Settings → YT Music**. Opening Lyrics
  while disabled displayed the consent prompt. Earlier Android acceptance
  loaded LRCLIB lyrics and verified tap-to-seek.
- A live Windows Dart probe matched a MusicBrainz recording and decoded its
  Cover Art Archive JPEG. An Android MusicBrainz request received HTTP 503 and
  retained stock artwork. A successful live Android community-cover fetch and
  physical TV input remain unverified. Widget tests exercise TV remote keys.

[Music behavior](../music.md) · [Implementation plan](../issue-41-music-plan.md)

## Android local build 60945

The persistent Android 16 emulator showed Continue Watching at the top of Your
Feeds, scrolled it out of view, and brought it back. A portrait Watch video
opened fullscreen using the right-hand control and exposed Repeat and the
combined speed and pitch controls.

Local music was initially disabled. Canceling Android's folder picker kept it
disabled. After granting access, Videre retained the selection across an app
restart, displayed two tagged files and embedded artwork, and played a local
track in the background. The controls changed speed to 1.25× and pitch by
one semitone independently. Forgetting the folder removed its tracks.

Music selected the highest-quality source by default. The emulator produced
tagged MP3, Ogg Opus, and M4A files in Android's shared audio collection.
FFprobe identified their respective MP3, Opus, and AAC streams. Auxio 4.1.5
loaded the shared folder and played the exported MP3 and a new M4A download.
The emulator also reproduced an accessibility overlap in YT Music settings.
In the corrected build, activating the format row opened its chooser and
preserved both provider switches.
