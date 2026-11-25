enum MusicTaskRemoval {
  stop,
  keepPlaying;

  static MusicTaskRemoval? fromStorage(String? value) =>
      values.asNameMap()[value];
}

enum MusicAudioOffload {
  disabled,
  whenSupported;

  static MusicAudioOffload? fromStorage(String? value) =>
      values.asNameMap()[value];
}
