enum MusicMiniPlayerLayout {
  automatic,
  compact,
  transport;

  static MusicMiniPlayerLayout? fromStorage(String? value) =>
      values.asNameMap()[value];
}

enum MusicMiniPlayerShortcut {
  automatic,
  next,
  repeat,
  shuffle;

  static MusicMiniPlayerShortcut? fromStorage(String? value) =>
      values.asNameMap()[value];
}
