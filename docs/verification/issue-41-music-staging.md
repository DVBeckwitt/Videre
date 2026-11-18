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

## Android local build 60946

The Android 16 emulator upgraded from 60945 with its saved account, music
folder, and local queue intact. In the TV interface, temporarily moving the
queued file produced a Retry button. Restoring the file and pressing Retry
played the saved song. On the phone interface, moving the approved folder
during background playback stopped the song on return, cleared its media
session title, and displayed the folder picker action. Selecting the same
folder again restored its songs without restoring the old queue. Forgetting
the folder immediately after a restart also preserved the audio file.

Two repeat exports of the same M4A used the same published Android audio row.
A device test moved a shared song out of Music/Videre, removed its Videre
entry, and verified the moved file byte for byte. In Your feeds, Continue
watching scrolled offscreen and back. A widget regression verified that adding
or removing the shelf on page two preserves the visible row and the loaded page.

Auxio's **Settings → Refresh music** picked up the shared MP3 on this emulator.
Android reported active Auxio playback for both the MP3 and M4A. In Videre,
opening Lyrics with LRCLIB disabled displayed its consent prompt. The portrait
Watch fullscreen control opened the full-screen player, and the speed control
opened the combined speed and pitch sheet.
