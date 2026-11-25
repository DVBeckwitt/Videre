enum MusicSongRowSwipeAction {
  off,
  playNext,
  addToQueue;

  static final _byName = values.asNameMap();

  static MusicSongRowSwipeAction? fromStorage(String? value) => _byName[value];
}
