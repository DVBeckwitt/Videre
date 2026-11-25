enum MusicSongTapQueueScope {
  collection,
  songOnly;

  static MusicSongTapQueueScope fromStorage(String? value) =>
      values.asNameMap()[value] ?? collection;
}
