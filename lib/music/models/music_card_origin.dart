enum MusicCardSurface {
  savedSongs,
  quickPicks,
  speedDial,
  keepListening,
  homeShelf,
  discovery,
  chart,
  recommendationCollection,
}

/// Identifies the card or collection control that launched a Music queue.
/// Collection and entry IDs are scoped to that card surface.
typedef MusicCardOrigin = ({
  MusicCardSurface surface,
  String? collectionId,
  String? entryId,
});
