const musicMinimumRecordingRating = 1;
const musicMaximumRecordingRating = 5;

bool isValidMusicRecordingRating(Object? value) =>
    value is int &&
    value >= musicMinimumRecordingRating &&
    value <= musicMaximumRecordingRating;

final _recordingIdPattern =
    RegExp(r'^(?:[A-Za-z0-9_-]{11}|device:[a-f0-9]{64})$');

/// Accepts a catalog recording ID or an opaque device track ID.
/// Queue occurrences and file locations are not recording IDs.
bool isMusicRecordingRatingId(String id) =>
    _recordingIdPattern.stringMatch(id) == id;
