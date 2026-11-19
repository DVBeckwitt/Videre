# Music UI source references

The music presentation uses the inspected Muzza revision
[`9e6cdc6be158e9699cf689970f30f279dddc2895`](https://github.com/Maloy-Android/Muzza/tree/9e6cdc6be158e9699cf689970f30f279dddc2895)
as its interaction reference. These are Flutter implementations over Videre's
existing player, catalog, library and profile services. Muzza's Kotlin services,
network clients, assets and branding are not embedded in this UI.

| Muzza reference | Videre implementation | Adaptation |
|---|---|---|
| [HomeScreen](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/screens/HomeScreen.kt) and [HomeViewModel](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/viewmodels/HomeViewModel.kt) | `lib/music/views/components/music_recommendation_shelves.dart`, `lib/music/views/screens/music_discovery.dart` | Compact four-row Quick Picks use the local Flow music ranker. Keep Listening uses this profile's actual music history. Discover automatically fetches a bounded selection through Invidious and ranks it locally. |
| [Player](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Player.kt), [Thumbnail](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Thumbnail.kt) and [MiniPlayer](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/MiniPlayer.kt) | `music_player.dart`, `music_mini_player.dart`, `music_track_swipe.dart` in `lib/music/views/components/` | Artwork, compact/full hierarchy, seek and transport remain presentation over the mounted decoder. Horizontal swipes use shared previous/next commands and retire on queue-occurrence, profile, session or width changes. Buttons remain available to keyboards, accessibility services and TV remotes. |
| [Queue](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Queue.kt) | `MusicQueue` in `music_player.dart` | Explicit drag handles and Move up/Move down actions use Videre's queue operations. The current occurrence stays highlighted; duplicate recordings retain distinct identities. |
| [LibraryMixScreen](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/screens/library/LibraryMixScreen.kt) and [LibraryPlaylistsScreen](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/screens/library/LibraryPlaylistsScreen.kt) | `lib/music/views/screens/music_library.dart` | Saved/title sorting and list/grid presentation operate on Videre's real songs, playlists and channels. A display sort does not rewrite library order. No album catalog is invented. |
| [PlayerMenu](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/menu/PlayerMenu.kt) | Existing `music_sound_sheet.dart` and `MusicSoundController` | Videre retains its in-app equalizer, speed and independent pitch. Muzza opens Android's system equalizer panel; those are deliberately different implementations. |

Muzza's source declares version 0.7.7. Its checked-in screenshot set shows 0.6.8,
so those images are visual references, not a claim of exact current-build parity.
Videre keeps Home/Search/Library and puts discovery/charts inside Home; Muzza's
source uses Home/Explore/Library with search in the top bar. Videre's existing
rounded-square primary transport control is retained.

Muzza includes the [GPL v3 license](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/LICENSE)
and credits InnerTune, OuterTune, Metrolist and OpenTune in its README. This UI
reference ledger is separate from the copied Flow algorithm provenance and the
native media-cache implementation.

All browsing, metadata, artwork and playback continue through Videre's existing
Invidious admission and transport. Music Home can warm an existing subscription
pool while learning is enabled. Active Music Home prepares Discover songs,
saved-artist selections, genre lists, and eligible Daily Mixes. It exposes a
recommendation shortcut only when the corresponding list contains eligible
tracks. Opening that shortcut uses the prepared list. A missing native ranker
hides Quick Picks. Library and history remain available, and user exclusions
still apply to discovery.

Typed search submissions and successful single-song saves can supply local
learning signals. Initial search shortcuts, retries, search-kind switches,
bulk playlist saves and imports do not manufacture extra activity. Pausing
learning also suppresses the automatic save signal; an optional learning error
does not undo a successful library change. Keep Listening follows actual history
updates even while learning is paused.

## Learned shelves and playable mixes

MusicBrain's actual `heavyRotation`, `timeOfDayRotation`, `rediscover`, and
`dailyMixes` functions provide ordered track IDs and learned co-listening seeds.
The application resolves shelf IDs against the active profile's eligible saved
tracks, listening history, and local playlists. On Repeat requires two tracks.
Time-of-day rotation and Rediscover each require three tracks after removing
On Repeat entries. The native time bucket supplies the rotation label. Source
for these presentation rules is Flow's `refreshLocalShelves` and `BrainShelf`.
[Flow MusicViewModel](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/screens/music/MusicViewModel.kt)
and [Flow MusicHomeSections](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/music/section/MusicHomeSections.kt).

`MusicRecommendationCollection` uses Muzza's artwork, count, Play All, Shuffle,
and selected-position queue behavior from `HomeScreen` and `LocalPlaylistScreen`.
Choosing a row starts its occurrence with the rest of the collection in the
queue. A recommendation collection needs no saved playlist or account identifier.
[Muzza HomeScreen](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/screens/HomeScreen.kt)
and [Muzza LocalPlaylistScreen](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/screens/playlist/LocalPlaylistScreen.kt).

Flow's daily mix expansion recalls related lanes for the learned seeds, ranks the
deduplicated pool as Discover, and requires at least four tracks. Videre prepares
up to three mixes in sequence on Music Home. Each uses up to three seed tracks
from listening history. Videre verifies up to eight candidates through the
selected Invidious instance and accepts at most six Music tracks per batch.
Ranking runs locally and excludes tracks already used by another mix. The shelf
displays only ready mixes, and opening one shows its prepared track list.
[Flow MusicBrainMixes](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/data/recommendation/music/MusicBrainMixes.kt).

## Immediate recommendations from existing follows

Video uses Flow's `bootstrapFromSubscriptions` name-token weights and its
current-follow ranking signal. Music uses MusicBrain's `setFavouriteArtist`
affinity floor on a temporary copy for followed creators with evidence in the
Music library or a category-verified Invidious upload. Both are current inputs
to ranking. They create no watch events, play counts, or saved likes. Unfollowing
removes the prior while preserving independent viewing and listening history.
[FlowNeuroEngine](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/data/recommendation/FlowNeuroEngine.kt)
and [MusicBrainLearn](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/data/recommendation/music/MusicBrainLearn.kt).

The active Home uses local follows and a short account-scoped name cache first.
It can then read one selected Invidious account's subscription list and feed,
plus one local channel's upload page if needed. Without account access the
local follow pool reads at most two upload pages. Music inspects at most eight
uploads and accepts up to six category-verified tracks from the expected
followed creators. Learning pause removes the prior. Profile, account, proxy,
and follow changes cancel results from older requests. The temporary account
cache contains only account identity and public channel names/IDs. Portable
backups exclude it.

## Player interaction ports

- Held songs and their overflow menus share Play, Play next and Add to queue
  across Music rows, cards and completed audio downloads. This translates
  Muzza's song menus and their separate next/tail commands into Videre's
  existing queue operations. Holding or dismissing the menu does not start
  playback. Next and Add retain the current recording, playback mode and
  queue order; online copies receive new occurrence IDs. Offline additions
  require completed downloads in the current profile and disable incompatible
  or already queued selections. Explicit Play keeps the row's collection or
  offline source. Invidious remains the online resolver.
  [SongMenu.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/menu/SongMenu.kt#L459),
  [YouTubeSongMenu.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/menu/YouTubeSongMenu.kt#L352)
  and [PlayerConnection.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/playback/PlayerConnection.kt#L158).
- `MusicTrackSwipe` translates the pinned compact player's 15% viewport drag
  threshold and the artwork's 25% threshold. The compact row exposes a direction
  indicator after 50 physical pixels. Videre checks the original profile and
  queue occurrence before applying the next or previous command. [MiniPlayer.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/MiniPlayer.kt#L92) and [Thumbnail.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Thumbnail.kt#L201).
- The expanded transport translates the previous/next tap and long-press
  combination. A long press seeks by Videre's existing skip interval. The same
  seek remains available as a separate accessible action. [Player.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Player.kt#L774).
- `MusicQueue` translates long-press selection, checkbox changes, selected
  tracks' command menu, queue edit locking, and the active row's play/pause
  toggle. At the user's request, swipe removal is replaced by holding a row
  and choosing Remove selected. Videre uses stable local occurrence IDs where
  Muzza uses Media3 window UIDs. Copies inserted next or at the tail get new
  occurrence IDs. Queue removal retains the item currently playing. Saving
  and audio downloading use Videre's profile-scoped library and Invidious
  download paths. [Queue.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Queue.kt#L552), [SwipeToSongBox.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/component/SwipeToSongBox.kt#L126), and [QueueSelectionMenu.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/menu/QueueSelectionMenu.kt#L112).
- The sleep dialog translates Muzza's 30-minute default, 5–120 minute range,
  five-minute steps, cancellation, and End of song choice. Active timers show
  remaining time. Videre's shared player pauses on completion or a transition
  to another occurrence when End of song is armed. Android Back dismisses the
  dialog before minimizing the player. [Queue.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Queue.kt#L174) and [SleepTimer.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/playback/SleepTimer.kt#L15).
- `playbackQueueTraversal` translates Muzza's timeline-window traversal into
  Videre's stable occurrence IDs and actual previous/current/upcoming order.
  It preserves the order from Shuffle and Play Next. The queue opens at the
  current track, cues play while paused, and lets the user reorder upcoming
  occurrences by drag or row menu. Shuffle and close remain available inside
  the queue. [PlayerExt.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/extensions/PlayerExt.kt#L34),
  [Queue.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Queue.kt#L516),
  and [PlayingIndicator.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/component/PlayingIndicator.kt#L86).
- Now Playing places artwork alongside controls on short landscape screens
  and supports opening and closing the queue beside the player on large
  screens. TV Music renders the same controls and queue under the existing
  audio decoder, with D-pad activation, Back to Now Playing, and restored
  focus when the queue closes. [Player.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Player.kt#L380)
  and [Player.kt landscape](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/player/Player.kt#L962).
- A downward swipe on the expanded Music header returns to the mini player.
  The gesture uses the header so the artwork keeps its track-swipe gesture
  and the queue keeps its own scrolling and reorder gestures. [Muzza BottomSheet.kt](https://github.com/Maloy-Android/Muzza/blob/9e6cdc6be158e9699cf689970f30f279dddc2895/app/src/main/java/com/maloy/muzza/ui/component/BottomSheet.kt).
  The pinned sheet's raw-delta/anchor pattern now also drives the expanded
  Flutter surface: it follows the finger without easing while held, then settles
  into explicit compact bounds or back to its expanded bounds. The 250ms
  decelerating Flutter settle honors the existing reduced-motion preference;
  it does not restart the mounted decoder. Video and its scrollable watch body
  share this gesture presentation. Horizontal gestures, text selection,
  additional pointers and cancellation retain their existing ownership.
  The downward-slop check and horizontal-first exit also translate the expanded
  drag arbitration in Flow's pinned
  [DraggablePlayerGestureHandler.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/videoplayer/motion/DraggablePlayerGestureHandler.kt#L115).
  Videre retains its 200dp release threshold and translates the expanded sheet
  while held; Flow instead interpolates its collapse fraction and uses velocity
  in the release decision.
