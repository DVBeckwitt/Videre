/// A content advisory read from a recognized recording tag.
/// A missing or unsupported advisory is represented by null.
enum MusicContentAdvisory {
  explicit,
  clean;

  static MusicContentAdvisory? fromPlatformCode(Object? code) => switch (code) {
        int value when value == 1 => explicit,
        int value when value == 2 => clean,
        _ => null,
      };
}

typedef PlayingMusicContentAdvisory = ({
  String queueId,
  int generation,
  MusicContentAdvisory advisory,
});
