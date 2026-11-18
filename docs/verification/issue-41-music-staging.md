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
