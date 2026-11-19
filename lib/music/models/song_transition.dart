enum SongTransitionMode {
  seamless,
  pause,
  fade,
  crossfade;

  static SongTransitionMode? fromStorage(String? value) =>
      values.where((mode) => mode.name == value).firstOrNull;
}

const minSongTransitionSeconds = 1;
const maxSongTransitionSeconds = 10;
const defaultSongTransitionSeconds = 3;
