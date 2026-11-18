# Videre local recommendations

Android-only Flutter plugin containing extracted Flow video and music algorithms.
See `ATTRIBUTION.md` for the exact upstream revision and adaptation ledger.

The method channel is `videre/recommendations`, method `evaluate`. Its argument is
`{domain, state, candidates, events, nowMs, seed, surface, subscriptionChannels}`. `domain` is `video` or
`music`; an empty state starts cold. The result is `{schemaVersion, domain, state,
ranked, summary}`. Ranked rows contain `id`, `score`, and `reason`; retain the
returned order because diversity composition follows numeric scoring.

Candidates use `id`, `title`, `author`, `authorId`, `durationSeconds`, `keywords`,
`description`, `category`, `genre`, `publishedMs`, `isLive`, `isShort`, `isUpcoming`,
`viewCount`, `likeCount`, `isSubscribed`, `artistKey`, and `artist` as applicable.
There are no media or artwork URLs. Missing metadata is allowed.

`subscriptionChannels` is an optional batch of up to 200 `{id, name}` rows from
the current admitted subscription source. IDs must be canonical channel IDs
and names can be at most 300 UTF-16 units. Video evaluates the actual Flow name
bootstrap in a temporary ranking view and applies its ordinary current-follow
boost. Music accepts only the host's verified Music creators and uses Flow's
favorite-artist floor in its temporary ranking view. Returned durable learning,
play counts and saved interest chips exclude these inferred priors. The host
can change or remove a follow without replaying or reversing listening events.

Events use a unique occurrence `id`, `type`, `candidate`, `playedMs`, `durationMs`,
and `timeMs`. Searches carry `query`. Both domains accept `listen`, `like`,
`dislike`, `skip`, `save`, `search`, `notInterested`, `block`, `unblock`. Video also
accepts actual `impression`, `click`, and `favorite` actions. Music skip/save/search
have no inferred learning weight. A listen is finalized once, using elapsed
playing time, never the seek position. Duplicate event IDs are ignored.
Video departures explicitly initiated by the viewer use the pinned classifier
with confirmed elapsed playing time. At 20% or more the occurrence teaches a
watch. A shorter departure teaches a skip after 10 seconds and otherwise
carries no skip signal. A rewind keeps the current occurrence. Feed
impressions record actual viewport exposure using the native recount window,
and confirmed explicit watch selections record one click per occurrence.

The host checkpoints an active occurrence after each 15 seconds of confirmed
playing time and when playback pauses or the app moves to the background.
The checkpoint carries the same event ID and cumulative elapsed time. It does
not change the native model. A normal finish sends the latest cumulative
event. After a process restart, the host can send the saved checkpoint as an
interrupted listen. The model, event deduplication ID and journal retirement
commit together in the profile's settings row. The last unsaved interval can
be lost on process termination. Learning toggles and reset clear the journal
and rotate the local consent epoch. Backups omit the journal and epoch.

Music surfaces are `quick_picks`, `heavy_rotation`, `radio`, `similar`, `discover`,
and `daily_discover`. Its summary exposes actual local `onRepeat`, `rediscover`,
`timeOfDay` track IDs and `dailyMixes` seeds; a ranker cannot invent candidates.
Video summary includes learned topics and bounded discovery-query proposals.
It also exposes Flow's stable interest chips and each chip's search queries.
The Dart application sends queries through Invidious only when the viewer
opens a chip or requests discovery. Video watch, like and save events may
carry up to ten existing `relatedChannels` IDs. Flow's strong-signal gate
and pair confirmation govern whether those relationships affect ranking.
Co-watch and channel category indexes are private to the local profile.

The channel executes on Flutter's background task queue. The caller serializes
events per profile, stamps async work with its profile/session generation, saves
returned state atomically, and discards stale replies. The plugin owns no files,
preferences, HTTP clients or native playback state. Clear the ephemeral video
`session` and music `sessionAnchor` at process start and profile switches.
Apply learning/history/pause settings before sending events. Reset means discarding
that domain's state; no automatic historical replay occurs.

State uses schema 1 and bounded primitive maps. Unknown schema, wrong domain,
malformed values, nonfinite numbers and oversized batches are rejected. A call
returns an error without mutating the input. Each batch permits at most 1,000
candidates and 1,000 events; event deduplication retains the latest 1,000 IDs.

From `android/`, use the repository-pinned JDK and Gradle wrapper:

```
./gradlew :videre_recommendations:testDebugUnitTest
./gradlew :videre_recommendations:connectedDebugAndroidTest
```

The Android tests exercise platform ICU segmentation and bundled language data.
Use Videre's persistent test AVD without wiping accounts or application data.
