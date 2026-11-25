/// A content advisory read from a recognized tag on the playing recording.
/// A missing or unsupported advisory is represented by null.
enum MusicContentAdvisory { explicit, clean }

typedef PlayingMusicContentAdvisory = ({
  String queueId,
  int generation,
  MusicContentAdvisory advisory,
});
