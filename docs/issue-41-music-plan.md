# Issue 41 Music on stock Invidious

Music uses the selected stock Invidious instance for YouTube search, metadata, artwork, and audio. Lyrics and community artwork have independent opt-ins under YT Music. The app requires no Invidious configuration change or custom route. [GitHub issue 41](https://github.com/DVBeckwitt/Videre/issues/41) · [Invidious API](https://docs.invidious.io/api/)

## Implement in Videre

1. Keep Music catalog queries and playback on the selected instance. Use its supported proxy paths and fail closed on foreign redirects. Bind responses to the track, account and instance that initiated them.
2. Add **Audio quality** to Music Now Playing. Offer **Auto** and the available decoder-compatible audio renditions from Invidious. Apply a choice to the current playback item and preserve position, paused or playing state, and queue. Represent downloaded audio separately.
3. Give Music songs a consistent artwork slot. Display a saved cover or an identifiable YouTube Art Track image, followed by the instance's stock video thumbnail and a local placeholder. Keep artwork provenance with the image. Artist and playlist images have their own roles.
4. Add **Lyrics** to Music Now Playing using the public LRCLIB database. Keep it disabled for each profile until the listener enables it in Settings or accepts the prompt in Now Playing. Query by song title, artist, known album and duration. Respect the app's configured network proxy. Display synced or plain database lyrics, instrumental status, or an unavailable state. Enable cue seeking for matched timed lyrics when the player can seek. [LRCLIB API](https://lrclib.net/docs.txt)
5. Add a separate **MusicBrainz and Cover Art Archive** switch under **YT Music**. Resolve covers for the visible Now Playing song, keep the stock image during lookup or on a miss, and reuse matched covers from a profile-local cache. Respect the configured proxy for API calls and vetted image redirects. [MusicBrainz recording search](https://musicbrainz.org/doc/MusicBrainz_API/Search#Recording) · [Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API)

## Stock API limits

The video API supplies video thumbnails, adaptive formats, caption tracks and optional music credit text. The published schema has no standard song release cover or dedicated lyrics endpoint. The stock description can identify automatically generated Art Tracks, which contain album art. The optional MusicBrainz and Cover Art Archive requests use separate HTTPS destinations from the Invidious request. [Video metadata](https://docs.invidious.io/api/#get-apiv1videosid) · [YouTube Art Tracks](https://support.google.com/youtube/answer/6007071)

## Acceptance

- Check selected-instance routing for Music and off-origin failures. Verify the optional LRCLIB lookup sends no request before consent, honors the proxy setting, and reads only verified database results, including a track with no lyrics.
- Check the quality control with multiple renditions, a single available rendition, decoder failure and offline audio. Verify playback position, pause, queue and instance survive a change. Run the applicable pinned Dart validation and Android checks on the existing signed-in test emulator.
- Record actual device behavior and provider coverage. The earlier optional extension experiment was retired when the stock-only requirement was confirmed. Its deployment and trial evidence is recorded separately. [Verification](verification/issue-41-music-staging.md)
