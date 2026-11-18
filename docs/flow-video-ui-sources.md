# Flow video UI source references

Recorded 17 November 2026. The presentation references the inspected Flow
revision [`565d1f7a3da4ca8e54463b029f151ef87415858a`](https://github.com/Flow-Tube/Flow/tree/565d1f7a3da4ca8e54463b029f151ef87415858a).
The browse port translates Flow's screen structure and selected interaction
code into Flutter over Videre's existing navigation, profiles and catalog
services. The Kotlin recommendation package has its own attribution ledger.

| Flow source at the pinned revision | Videre destination | Referenced presentation and adaptation |
|---|---|---|
| [HomeScreen.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/screens/home/HomeScreen.kt), [HomeFeedGrid.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/screens/home/HomeFeedGrid.kt) | `lib/home/views/components/home.dart`, `flow_video_home.dart` in the same directory | Compact header, topic chips, continuation shelf and responsive feed hierarchy. For you ranks locally known or explicitly discovered candidates; Your feeds retains Videre's configured layout. Topic chips now use FlowNeuro's learned interest groups and stable chip selection; submitted search history remains an optional learning input. |
| [VideoCardStacked.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/shared/card/VideoCardStacked.kt) | `video_in_list.dart`, `video_thumbnail.dart`, `video_metrics.dart`, `compact_video.dart`, `recommendation_actions.dart` in `lib/videos/views/components/` | Prominent rounded artwork, neutral titles, restrained secondary metadata, accessible overflow actions and local recommendation explanations/feedback. Videre retains its duration/progress badges, guarded artwork loader and existing playback actions. |
| [SearchScreen.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/screens/search/SearchScreen.kt), [SearchHistoryMatching.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/search/SearchHistoryMatching.kt), [SearchSuggestionsPanel.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/search/SearchSuggestionsPanel.kt), [SearchFilterBar.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/search/SearchFilterBar.kt) | `lib/search/states/search.dart`, `lib/search/views/screens/search.dart`, `lib/search/views/components/search_history_matching.dart`, `search_suggestions_panel.dart` | Translates prefix-first history matching and the first-eight reveal rule, separates fill from submit, preserves results while editing, and restores the submitted query on Back. Type and recent-upload chips use Videre's existing Invidious service. |
| [ChannelContent.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/screens/channel/ChannelContent.kt), [ChannelHeaderSection.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/channel/ChannelHeaderSection.kt), [ChannelTabRow.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/channel/ChannelTabRow.kt), [ChannelFilterBar.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/channel/ChannelFilterBar.kt) | `lib/channels/views/screens/channel.dart`, `lib/channels/views/components/info.dart`, `sort_dropdown_button.dart` | Shared collapsible banner and identity, pinned top tabs, expandable About, featured and compact uploads, and a menu chip for sort. The lead item comes from the latest visible uploads available through Invidious. |
| [PlaylistDetailHeader.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/library/PlaylistDetailHeader.kt), [FlowActionButtonPair.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/shared/FlowActionButtonPair.kt) | `lib/playlists/views/components/flow_playlist_header.dart`, `playlist_playback_actions.dart`, phone and tablet `playlist_inner_view.dart` | Port of the single 16:9 cover, title and metadata stack, expandable description, connected Play all and Shuffle controls, and secondary actions. Videre supplies playlist paging, admission, queue ownership and saving. |
| [VideoInfoSection.kt](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/app/src/main/java/io/github/aedev/flow/ui/components/videoplayer/info/VideoInfoSection.kt) | `lib/videos/views/components/info.dart`, `recommended_videos.dart` | Neutral selectable titles and grouped channel/subscription information. Already-loaded Invidious related videos are re-ranked locally. Existing description, tags, copy/selection behavior, channel navigation and community-hidden reveal controls remain. This is a details/related-content adaptation, not a replacement player or decoder. |

Videre exposes Music as a movable bottom destination, immediately before Search
by default, with no top-left mode switch. Music's Home, Search and Library stay
inside its section. For you/Your feeds is inside Videos Home; customizable tabs,
tablet navigation, subscriptions, history, playlists and downloads remain.
TV exposes For you through
`lib/app/views/tv/screens/tv_home.dart`, using Videre's existing TV cards and
remote navigation. Keyed cards preserve the correct playback target after
re-ranking, and menu controls retain their focus when switching modes.

Opening For you ranks local metadata and existing follows. With learning enabled,
an active Home can read a bounded followed-channel candidate pool through the
selected Invidious instance. Inferred topic searches still require an explicit
action. Continue
Watching uses cached history and excludes completed, watched, music and excluded
entries. Discover videos and interest chips request bounded candidates through
the selected Invidious instance. The native bridge uses the pinned
`HomeChipPolicies.interestQueries` and `NeuroDiscovery.generateQueries`.
An explicit Discover action sends Flow's topic queries; the separately bounded
subscription warm start supplies followed-channel candidates. These views add no direct YouTube connection,
extractor, media resolver or upstream artwork loader. Share/playback actions
continue through Videre's existing services. A missing native ranker displays
eligible unranked items with an explicit status; it does not invent scores or
explanations. Profile/session and active-surface checks discard stale results.

Flow includes the [GPL v3 license](https://github.com/Flow-Tube/Flow/blob/565d1f7a3da4ca8e54463b029f151ef87415858a/License).
This UI reference ledger is separate from the copied Kotlin algorithm notices
and [native cache provenance](download-playback-sources.md).

## Browse interactions translated from Flow source

| Flow source at `565d1f7a` | Videre destination | Behavior |
|---|---|---|
| `screens/home/ImpressionDwell.kt`, `HomeFeedBody.kt`, `HomeViewModel.kt` | `lib/home/views/components/flow_video_home.dart` | A ranked Home card must remain at least half visible for one second in the active foreground viewport. Confirmed impressions are batched through FlowNeuro. Route changes, profile changes, covered playback, and leaving the viewport cancel pending observations. |
| `components/home/ContinueWatchingShelf.kt`, `screens/home/HomeViewModel.kt`, `data/local/ViewHistory.kt` | `flow_video_home.dart`, `lib/videos/views/components/video_in_list.dart` | A close button removes the selected video's local history and progress for the active profile under Videre's existing history deletion rules. |
| `components/search/SearchTopBar.kt`, `SearchResults.kt`, `SearchChannelHeroCard.kt`, `components/shared/card/VideoCardRow.kt` | `lib/search/views/screens/search.dart`, `video_tab.dart`, `lib/search/views/components/search_channel_hero_card.dart`, `lib/videos/views/components/video_list.dart` | The Search toolbar switches the result presentation and shows the active filter count. Stacked and thumbnail-left cards share the same page owner. Creator cards use search response metadata, with subscription controls loaded after the user opens them. |
| `screens/channel/ChannelContent.kt`, `ChannelViewModel.kt`, `ChannelSearchResults.kt`, `components/channel/ChannelTabItems.kt` | `lib/channels/views/screens/channel.dart`, `lib/channels/views/components/channel_search.dart`, `videos.dart` | Channel uploads use the shared stacked cards. Search switches to channel results while preserving the previous tab. Videre sends a submitted query and pages through the selected instance using the [Invidious channel search endpoint](https://docs.invidious.io/api/channels_endpoint/#get-apiv1channelsucidsearch). |

## Phone watch interactions translated from Flow source

The watch page uses the same pinned revision. These components translate the
upstream interaction and layout code into Videre's Flutter player and services.

| Flow component | Videre implementation | Behavior |
|---|---|---|
| `VideoInfoSection.kt` and `VideoInfoContent.kt` | `lib/videos/views/components/flow_watch_body.dart` | Tap the title or metadata to open Description. Long press copies the title. Channel, subscriber count, subscriptions and watch actions use Videre data. |
| `CommentsPreview.kt` and `PlayerCommentsPanel.kt` | `flow_watch_body.dart`, `lib/comments/views/components/comments_container.dart`, `comments.dart` | Show the first top comment, avatar and count when supplied by the selected Invidious instance. The panel reuses the completed top page and offers Top and New sorting. Preview follows the existing distraction-free setting. |
| `PlayerBottomBar.kt`, `PlayerTimePill.kt`, `PlayerIdleProgressStrip.kt` and `MediaSeekBarEdgeAligned.kt` | `lib/player/views/components/flow_watch_transport.dart`, `player_controls.dart` | The phone portrait timeline sits at the edge of the media. Its touch target still seeks while main controls are hidden. Confirmed buffer and admitted SponsorBlock intervals appear as separate bands. Tapping the time pill switches elapsed and remaining time. |
| `PlaylistQueueDock.kt` and `EnhancedVideoPlayerScreen.kt` | `lib/player/views/components/flow_watch_queue_dock.dart`, `expanded_player.dart` | A floating dock shows the actual next occurrence in playback order and opens the existing queue. Single videos retain a queue shortcut. |

The portrait watch page keeps Videre's mounted decoder, seek preview, duration,
session rules and captions. Comments and thumbnails use the existing guarded
Invidious services. Playback, repeat, downloads and subscriptions continue
through Videre's own commands. The adaptive watch layouts below extend the
expanded player to tablets. TV and fullscreen keep their existing controls.

## Floating video mini-player

These components follow Flow revision `565d1f7a3da4ca8e54463b029f151ef87415858a`.

| Flow source | Videre implementation | Behavior |
|---|---|---|
| `motion/DraggablePlayerGeometry.kt`, `DraggablePlayerDragMath.kt`, `MiniPlayerResnap.kt` | `lib/player/models/flow_mini_geometry.dart` | Default 45% phone width, capped desktop sizing, initial bottom-right corner, 8 dp margins, elastic drag, velocity projection, corner snap, nearby-edge tuck and downward dismissal. |
| `motion/MiniPlayerPinchGestureHandler.kt`, `DraggablePlayerGestureHandler.kt`, `MiniPlayerTapDecider.kt` | `lib/player/views/components/flow_floating_mini.dart` | Track two fingers in screen space to resize around the saved corner. Releasing snaps to compact or wide. Double tap toggles size and single tap expands after the platform's double-tap window. |
| `MiniPlayerTuckHandle.kt`, `MiniPlayerControls.kt`, `screens/player/stage/MiniPlayerSlot.kt` | `flow_floating_mini.dart` | Position the inward-facing tab at the tucked edge. Tap or drag it to restore the player. The live video surface carries play, replay, close, progress and queue controls when space permits. |
| `DraggablePlayerLayout.kt` and `DraggablePlayerVideoBox.kt` | `lib/player/views/components/player.dart`, `mini_player_aware.dart` | Keep one decoder subtree through floating, pinch, expanded and PiP transitions. Animate its Flutter layout rectangle over the existing route. Insets, keyboard and navigation constrain the floating player on phones and tablets. |

Flow's pixel-per-second gesture thresholds use Flutter's device pixel ratio.
Videre derives placement from its own navigation and safe area. The Music mini
bar retains the Muzza layout, and the TV player retains its remote focus path.

## Adaptive watch layout and gestures

These translations use Flow `565d1f7a` and Videre's existing player, settings,
queue and Invidious catalog.

| Flow source | Videre implementation | Behavior |
|---|---|---|
| `screens/player/state/PlayerLayoutMode.kt`, `PlayerDetailPanes.kt`, `VideoPlayerHost.kt`, `EnhancedVideoPlayerScreen.kt` | `lib/player/models/flow_watch_layout.dart`, `lib/player/views/components/player.dart`, `expanded_player.dart` | Compact below 600 dp width or 480 dp height, medium from 600 dp, and two panes from 840 dp in landscape. The medium layout gives related videos a grid under the player. Wide layout reserves 384 dp for the supporting pane and falls back to one column when safe insets leave insufficient space. The same decoder stays mounted while the window changes. |
| `screens/player/content/PlayerDetailSideColumn.kt` and `state/QueueDockState.kt`, `components/videoplayer/sheet/PlaylistQueueDock.kt` | `flow_watch_side_pane.dart`, `flow_watch_queue_dock.dart`, `lib/videos/views/components/flow_watch_body.dart` | Wide windows show related content and the queue card beside the video. Description, comments, settings and queue open in that pane and Back restores the related list. Compact and medium windows use a dock under the watch page. Queue predictions use Videre's next occurrence, repeat mode and playlist paging; an ended queue stays accessible. |
| `components/videoplayer/sheet/FlowPlaylistQueueBottomSheet.kt`, `player/PlaylistQueueOrder.kt` | `lib/player/views/components/video_queue.dart` | Active queues show the same playback order as the dock. The existing shared occurrence traversal preserves repeated recordings, visited entries, shuffle and Play next. Rows select by occurrence, and dragging changes the order of upcoming items without moving the current video. A dormant queue keeps its existing start and reorder behavior. |
| `screens/player/stage/PlayerBodySlot.kt`, `VideoPlayerViewModel.kt` | `lib/videos/views/components/recommended_videos.dart` | Selecting a related card in active Watch starts that video with Videre's normal guarded playback and replaces the previous queue. Related cards in preview still open a preview. |
| `components/videoplayer/gesture/PlayerTapGestures.kt`, `PlayerGestureModifier.kt`, `PlayerDragGestures.kt` and `data/local/PlayerPreferences.kt` | `lib/player/views/components/flow_video_gestures.dart`, `player_controls.dart` | The center third toggles playback on double tap, the outer thirds seek, and repeated same-side taps continue a seek series. Horizontal drags preview a position within a span of up to 90 seconds and commit on release. Gestures avoid system edges and retain Videre's seek-step settings, controls and fullscreen device adjustments. |

Save, Share and the nested playlist form use Videre's player modal Back
handling. Share offers a selected-instance Invidious URL or an explicit YouTube
URL, each with an optional playback timestamp. Both are constructed locally;
playback and content requests remain on Invidious. Device-file playback
keeps its existing details layout. The TV retains its existing remote controls,
and fullscreen and PiP give the video the window without an adjacent pane.

The Watch reaction metric also translates `VideoActionRow.kt`'s call to
`utils/FormatUtils.kt` (`formatViewCount`): locale-aware short compact numbers
use Flutter's `NumberFormat.compact`, without currency-style trailing decimals.
Delayed dislike results still share Videre's existing request owner and remain
read-only aggregate counts, separate from recommendation feedback.
