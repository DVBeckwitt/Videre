# Saved media before playback cache

The source-ordering precedent is Muzza revision
[`9e6cdc6be158e9699cf689970f30f279dddc2895`](https://github.com/Maloy-Android/Muzza/tree/9e6cdc6be158e9699cf689970f30f279dddc2895),
specifically `MusicService.kt`'s
[`createCacheDataSource` and `createDataSourceFactory`](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/playback/MusicService.kt#L1243).
Its read-only download cache precedes its evictable player cache and network
source. Videre adapts that ordering to its existing private files and Android
Storage Access Framework documents, and retains its existing playback owners.

`DownloadPlaybackProvenance` records the completed file's SHA-256 and length,
profile/account/original instance/content, container, default-audio selection,
actual video height, and immutable input rendition identities. Source URLs and
credentials are excluded. Audio-only files retain their original bytes; merged
video has an independent whole-file fingerprint and both input identities.

`prepareDownloadedPlaybackVideo` can select a compatible completed rendition
before online metadata loading. It preserves the online queue occurrence and
admitted connection snapshot without inventing a media URL. Existing current
format metadata, when available, must also match the saved immutable renditions.
Without that metadata, the saved proof must match the active owner, instance,
content, playback mode, default audio, and any explicitly requested video height.

The ordinary video details route publishes that saved candidate before waiting
for online metadata, so a normal video tap can reach local playback while the
instance is unavailable. Optional metadata enrichment restores descriptions and
related videos without triggering autoplay a second time. Failed enrichment
keeps the saved candidate; profile, account, credential and proxy changes retire
stale results.

Music's single-song route uses the same saved-source preparation before its
catalog request, including taps from recommendation and discovery shelves.
Only saved music metadata supplies a local song identity. Complete saved Music
metadata starts this route once with its saved song details. Unavailable or
incompatible saved sources use the existing catalog path.

Both native players receive a dedicated progressive local candidate, followed
by the ordinary admitted Invidious sources. `DownloadedRendition` verifies the
digest on the loader thread using the same descriptor subsequently read by the
decoder. Seeks reuse the verified fingerprint; later opens/reads check identity,
length, modification state, and persisted document permission. Invalid local
media is skipped at the source boundary. If no online metadata exists yet,
Videre obtains real metadata through its existing current-route recovery path.
A failed local candidate is not repeatedly selected during that recovery.

Unlike Muzza's song-ID cache key, admission remains scoped to the current
profile, account, selected instance, and proxy/authentication session. Local
bytes bypass the evictable cache; remuxed offsets never alias an original
network representation. No upstream extractor, stream validation request, or
direct YouTube transport is imported. Cache clearing does not delete downloads.

The evictable cache follows Muzza's separate `playerCache` precedent in
[`AppModule.kt:54`](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/di/AppModule.kt#L54).
Videre keeps one shared native cache owner and its own guarded upstream. Media3
1.4.1's typed HLS data-source requests and separate DASH chunk/manifest factories
identify adaptive media requests. An admitted media child absent from the
immutable rendition map uses a distinct session-only URI key only when metadata
explicitly identifies non-live content; missing live classification retains the
previous mapped-resource-only policy. Manifests, encryption-key requests and
known-live sources bypass the byte cache. This
request classification is a Videre adaptation, not copied YouTube resolution
code or a new decoder.

SponsorBlock remains Videre-owned behavior, separate from Muzza's cache code.
Video and Music entry points prime the player's existing bounded segment cache
alongside metadata loading. In-flight lookups are shared with source setup.
Automatic saved playback can supply segment metadata from the same admitted
download record; current category settings and interval validation still apply.
Available initial segments adjust setup before decoding, optional lookup failure
preserves the saved fallback, and late segments seek the existing decoder.
Neither preparation nor enrichment is a prerequisite for starting playback.

Legacy downloads and downloads with incomplete immutable provenance retain
explicit offline playback. They are not silently assigned new ownership or
representation proof. The added JSON field is optional and does not migrate or
delete existing records or files.
