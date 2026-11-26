enum MusicSongTapQueueScope {
  collection,
  songOnly,
  allSongs,
  album,
  artist,
  genre;

  bool get usesDeviceLibrary => this != collection && this != songOnly;

  static MusicSongTapQueueScope fromStorage(String? value) =>
      values.asNameMap()[value] ?? collection;
}
