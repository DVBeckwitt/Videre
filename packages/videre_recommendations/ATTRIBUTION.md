# Flow recommendation extraction

This package contains code from **Flow Android Client**, copyright 2025–2026
Flow / A-EDev, at revision
[`565d1f7a3da4ca8e54463b029f151ef87415858a`](https://github.com/Flow-Tube/Flow/tree/565d1f7a3da4ca8e54463b029f151ef87415858a).
Flow's GPL v3 text is retained in `LICENSE`; original source notices remain in
the derived Kotlin files. Videre's adapters do not imply endorsement by Flow.

The destination source prefix below is
`android/src/main/kotlin/com/github/dvbeckwitt/videre/recommendations/`.
The upstream prefix is
`app/src/main/java/io/github/aedev/flow/data/recommendation/`.

| Upstream source | Destination | Adaptation |
|---|---|---|
| `NeuroModels.kt` | `video/NeuroModels.kt` | Package changed; UI resource references removed from persona enum; supplied clock added to time buckets; Videre schema and counted-document IDs made explicit. |
| `NeuroScoring.kt`, `NeuroVectorMath.kt`, `NeuroCategories.kt`, `NeuroFormats.kt`, `NeuroClusters.kt`, `NeuroPhrases.kt`, `NeuroKeySpec.kt`, `NeuroChunker.kt`, `NeuroTopicCatalog.kt`, `NeuroLanguages.kt`, `NeuroSpecificity.kt`, `NeuroSearchLearning.kt`, `RankTrace.kt`, `InterestChips.kt` | Corresponding `video/` files | Package/import adaptation; unchanged mathematical functions/constants. The video-engine reference for the co-watch coefficient is replaced with its original `0.04` constant. |
| `NeuroTokenizer.kt`, `NeuroText.kt`, `NeuroStemmer.kt` | Corresponding `video/` files | Original multilingual processing and data retained; `ThreadLocal.get()` values explicitly checked for the pinned Kotlin/JDK nullability contract. |
| `NeuroDiscovery.kt` | `video/NeuroDiscovery.kt` | Supplied time also determines year and time bucket; query proposals never execute network requests. |
| `NeuroDisplayForms.kt` | `video/NeuroDisplayForms.kt` | Serialization annotations removed; Videre serializes primitive state maps. |
| `ChannelMemory.kt` | `video/ChannelMemory.kt` | Flow's database-specific history projection removed. Pure rejection/memory rules retained; retrieval remains a Dart concern. |
| `FlowNeuroEngine.kt`, event learning, persona, rejection and rank orchestration | `video/VideoLearning.kt`, `video/VideoEvaluator.kt` | State/clock/event identity passed in; Android singletons, persistence, jobs and remote providers removed. Actual upstream vector, IDF, channel, topic, category, format and language rules retained. |
| `FlowNeuroEngine.interestChips`, `NeuroCategoryStore.kt`; `ui/screens/home/chips/HomeChipPolicies.interestQueries` | `video/VideoDiscovery.kt` | Pinned cluster evidence, stable chip selection, category confidence, and chip query composition. Dart controls when selected queries become Invidious requests. |
| `FlowNeuroEngine.bootstrapFromSubscriptions`, `music/MusicBrainLearn.setFavouriteArtist` | `video/VideoSubscriptionPrior.kt`, `music/MusicEvaluator.kt` | Flow's capped name and pair weights plus the music favorite-artist affinity floor calculate in temporary ranking views. Dart supplies admitted current follows and verifies Music metadata. Blocks and genuine learning survive changes to follows. |
| `NeuroCoWatchStore.kt` | `video/NeuroCoWatchStore.kt` | Original pair confirmation, decay and strongest-neighbour scoring. Related channel IDs come from existing admitted Invidious metadata after a strong signal. The indexes stay in device-local Videre profile storage and are omitted from backups. |
| `ui/screens/player/WatchSessionTracker.kt` (`watchSignalFor`) | `video/VideoEvaluator.kt` | Flow's 20% watched threshold and 10-second navigation-noise floor grade deliberate departures using confirmed elapsed time. Videre preserves neutral handling of interrupted playback. |
| `music/MusicBrainModels.kt`, `MusicBrainLearn.kt`, `MusicBrainRanker.kt`, `MusicBrainMixes.kt` | Corresponding `music/` files | Package changed. Ranker's original score exposed internally for diagnostics; rank order still follows novelty composition and artist spreading. |
| `music/MusicBrainEngine.kt`, `MusicBrainShelves.kt` | `music/MusicEvaluator.kt` | New pure adapter uses upstream learning/ranking/shelf functions. No automatic history backfill, media URLs or Android state stores. |
| `app/src/main/java/org/tartarus/snowball/` | `android/src/main/java/org/tartarus/snowball/` | Snowball 3.1.1, pinned by Flow to `cd195b51e948a902a4312f023f4a14392516a543`. Generated stemmers/tables are unchanged; unused callback support in `Among`/`SnowballProgram` removed for API 24 compatibility, as detailed below. |
| `app/src/main/resources/neuro/` | `android/src/main/resources/neuro/` | Unmodified stop lists, word frequencies, key lists, Han conversion and topical data. |

`THIRD_PARTY_NOTICES.txt` is copied from Flow's
`app/src/main/assets/licenses/notices.txt`. It includes Snowball's BSD notice,
stopwords-iso's MIT notice, FrequencyWords/OpenSubtitles CC BY-SA 4.0 attribution,
and OpenCC Apache 2.0 attribution. Notices and GPL text are also packaged as Android
assets; the Dart API registers attribution/data notices with Flutter's license UI.

Implementation adaptations are explicit:

- Video and music state remain independent. No Flow extractor, InnerTube client,
  media service, HTTP client, DataStore or repository is part of this package.
- All 1,059 `Among` entries in the seven pinned generated stemmers use the
  three-argument constructor and no callback. The unused `MethodHandle` callback
  constructor/branches are removed from the Snowball support classes because
  Android only supports `invokeExact` from API 26. This preserves Videre's API 24
  floor without changing generated stemming rules; adding callback-based upstream
  tables later requires an explicitly compatible implementation.
- Candidates carry metadata only. Missing artist identity is not inferred from
  an uploader; missing video creator identity does not train a shared empty key.
- Invidious publication timestamps are projected to Flow's relative-age bands.
  Unknown publication dates remain unknown. Genre remains optional.
- Actual playing time determines listen fractions; unknown/zero video durations
  do not create negative feedback. One event describes a finalized occurrence.
  Videre uses the cumulative occurrence semantics in Flow
  `service/Media3MusicService.finalizeListenSession` and
  `MusicBrainEngine.onListenSession` / `awaitWrites`.
  Muzza's pinned `playback/MusicService.kt` uses a periodic queue save and another
  save at service teardown. Videre adapts that cadence to its own elapsed-time
  recommendation journal in `lib/recommendations/playback_checkpoint.dart`.
  Only the finalized or recovered event enters Flow's milestone logic.
- Stable event IDs deduplicate retries within a bounded 1,000-ID history.
  Native evaluation has no durable effects before Dart accepts and saves its result.
- Session state is passed through the caller and expires. The caller clears
  `session` / `sessionAnchor` at process start and profile switches.
- Co-watch and category-channel priors use original rules with the metadata
  Videre already received. Missing related lists and categories remain neutral.
  Flow's remote graph backfill and Android full-video metadata store are outside
  this extraction.
- Permanent manual blocks are bounded, explicit state. Temporary video creator
  suppression is capped at the latest 100 entries; copied upstream code only
  removed expired entries when its named cap was exceeded.
- Dart applies existing content-filter decisions before supplying candidates.
  Native rankers still apply their own preference blocks, suppression and seen gates.
- Music save/search/skip events do not invent upstream preference weights.
  Likes and elapsed listens use actual MusicBrain functions; repeated listening
  is rewarded independently of video seen suppression.
- Flow `HomeViewModel.recordImpressions`, `FeedImpressionLedger.kt` and
  `PlaybackSessionApplier.recordWatchClick` guide Videre's viewport and
  confirmed explicit watch inputs. The existing native recount rule grades
  actual visible cards. An automatically advanced or restored occurrence
  does not create a click.
- Creator controls in Flow `ui/screens/settings/taste/HiddenContentScreen.kt`
  remove a single hard block through `FlowNeuroEngine.unblockChannel` or
  `MusicBrainLearn.unblockArtist`. Videre applies those set removals to the
  native and profile snapshot together and keeps the remaining feedback.
- Music metadata excludes artwork URLs. Its session anchor is serialized only
  for stateless calls; genre/time-bucket collections and import sizes are bounded.
- State codecs are Videre-specific and are not an import promise for arbitrary
  Flow Android/desktop backup formats or later upstream schema versions.

Tests retain or adapt pinned upstream scoring, IDF, learning and Android
segmentation fixtures, alongside Videre DTO/isolation/retry tests. They establish
specified behavior, not identical end-to-end recommendations: the candidate
sources, metadata availability and excluded app services differ intentionally.
The upstream Android Chinese segmentation fixture predates its current key-spec
3 rules. Its adapted assertions require Simplified `新闻` for Traditional `新聞`,
matching upstream `NeuroHanRunsTest` and `key_spec_golden.json`; `教学` is required
as the `tutorial` format instead of a topic, matching `NeuroFormats`, and the
Chinese stop-list removal of `入门` is asserted separately.
