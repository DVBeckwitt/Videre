part of 'recommendation_service.dart';

class _MusicDismissal {
  final RecommendationCandidate candidate;
  final String eventId;
  final RecommendationSnapshot before;
  final RecommendationSnapshot after;

  const _MusicDismissal(this.candidate, this.eventId, this.before, this.after);

  RecommendationSnapshot? restore(RecommendationSnapshot current) {
    if (!current.eventIds.contains(eventId)) return null;
    final track = candidate.id;
    final artist = candidate.creatorKey;
    final addedTrack =
        !before.blockedIds.contains(track) && after.blockedIds.contains(track);
    final addedArtist = !before.blockedCreators.contains(artist) &&
        after.blockedCreators.contains(artist);
    if ((addedTrack && !current.blockedIds.contains(track)) ||
        (addedArtist && !current.blockedCreators.contains(artist))) {
      return null;
    }
    return current.copyWith(
      state: current.encode() == after.encode()
          ? before.state
          : _restoreArtistState(current.state, artist),
      blockedIds: {...current.blockedIds}..removeAll([if (addedTrack) track]),
      blockedCreators: {...current.blockedCreators}
        ..removeAll([if (addedArtist) artist]),
      blockedCreatorLabels: {...current.blockedCreatorLabels}
        ..removeWhere((key, _) => addedArtist && key == artist),
      revision: current.revision + 1,
    );
  }

  // Other signals may have committed since the dismissal. Patch the values
  // that still belong to it, keeping newer changes and other artists' data.
  Map<String, dynamic> _restoreArtistState(
      Map<String, dynamic> current, String artist) {
    final state = {...current};
    for (final field in [
      'artistAffinity',
      'dislikedArtists',
      'recentRotation'
    ]) {
      final original = _artistValues(before.state[field])[artist];
      final dismissed = _artistValues(after.state[field])[artist];
      final values = _artistValues(current[field]);
      if (!_sameValue(original, dismissed) &&
          _sameValue(values[artist], dismissed)) {
        final restored = {...values, if (original != null) artist: original}
          ..removeWhere((key, _) => original == null && key == artist);
        // Do not evict an independent entry if this map filled in the meantime.
        if (validNativeSnapshot({...state, field: restored})) {
          state[field] = restored;
        }
      }
    }
    const blockField = 'blockedArtists';
    final existingBlocks = current[blockField];
    if (existingBlocks is List &&
        existingBlocks.contains(artist) &&
        _hasArtist(after.state[blockField], artist) &&
        !_hasArtist(before.state[blockField], artist)) {
      state[blockField] = existingBlocks.where((key) => key != artist).toList();
    }
    const appetite = 'discoveryAppetite';
    if (before.state[appetite] != after.state[appetite] &&
        current[appetite] == after.state[appetite]) {
      if (before.state[appetite] case final original?) {
        state[appetite] = original;
      } else {
        state.remove(appetite);
      }
    }
    return state;
  }

  Map<Object?, Object?> _artistValues(Object? value) =>
      value is Map ? value : const {};

  bool _sameValue(Object? a, Object? b) =>
      a is Map && b is Map ? mapEquals(a, b) : a == b;

  bool _hasArtist(Object? value, String artist) =>
      value is List && value.contains(artist);
}
