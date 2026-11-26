/// Evidence shared by the missing file and a possible replacement.
enum LocalMusicMoveReason { revision, tags }

class LocalMusicMoveCandidate {
  final String id;
  final LocalMusicMoveReason reason;

  const LocalMusicMoveCandidate._(this.id, this.reason);
}

/// Display metadata from a previously indexed file. It has no playable URI.
class LocalMusicMissingTrack {
  final String id;
  final String title;
  final String? fileName;
  final String? artist;
  final String? album;
  final String? folder;
  final int durationMs;
  final List<LocalMusicMoveCandidate> candidates;

  const LocalMusicMissingTrack._({
    required this.id,
    required this.title,
    this.fileName,
    this.artist,
    this.album,
    this.folder,
    this.durationMs = 0,
    required this.candidates,
  });
}

/// An authorized catalog snapshot. Aliases retain older occurrence IDs without
/// adding duplicate tracks to the library listing.
class LocalMusicRepairSnapshot {
  static final _id = RegExp(r'^device:[0-9a-f]{64}$');
  static final _playlistProof = RegExp(r'^[0-9a-f]{64}$');

  final Map<String, LocalMusicMissingTrack> missing;
  final Map<String, String> aliases;
  final Map<String, String> missingAliases;
  final Map<String, String> playlistAliases;
  final Map<String, String> missingPlaylistIds;

  const LocalMusicRepairSnapshot.empty()
      : missing = const {},
        aliases = const {},
        missingAliases = const {},
        playlistAliases = const {},
        missingPlaylistIds = const {};

  const LocalMusicRepairSnapshot._(
    this.missing,
    this.aliases,
    this.missingAliases,
    this.playlistAliases,
    this.missingPlaylistIds,
  );

  LocalMusicMissingTrack? missingTrack(String id) =>
      missing[id] ?? missing[missingAliases[id]];

  factory LocalMusicRepairSnapshot.fromChannel(
    Map<String, dynamic> data,
    bool Function(String) indexed,
  ) {
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value : null;

    final missing = <String, LocalMusicMissingTrack>{};
    if (data['missing'] case List rows) {
      for (final row in rows.whereType<Map>()) {
        final id = _trackId(row['id']);
        final title = text(row['title']);
        if (id == null || title == null || indexed(id)) continue;
        final candidates = <String, LocalMusicMoveCandidate>{};
        if (row['candidates'] case List matches) {
          for (final match in matches.whereType<Map>()) {
            final candidate = _trackId(match['id']);
            final reason = switch (match['reason']) {
              'revision' => LocalMusicMoveReason.revision,
              'tags' => LocalMusicMoveReason.tags,
              _ => null,
            };
            if (candidate != null && reason != null && indexed(candidate)) {
              candidates[candidate] = LocalMusicMoveCandidate._(
                candidate,
                reason,
              );
            }
          }
        }
        final duration = row['durationMs'];
        missing[id] = LocalMusicMissingTrack._(
          id: id,
          title: title,
          fileName: text(row['fileName']),
          artist: text(row['artist']),
          album: text(row['album']),
          folder: text(row['folder']),
          durationMs: duration is int && duration > 0 ? duration : 0,
          candidates: List.unmodifiable(candidates.values),
        );
      }
    }

    Map<String, String> readAliases(
      Object? value,
      bool Function(String) target, {
      required bool Function(String) usable,
      bool playlist = false,
    }) {
      if (value is! Map) return const {};
      final aliases = <String, String>{};
      for (final row in value.entries) {
        final from = _validId(row.key, playlist ? _playlistProof : _id);
        final to = _trackId(row.value);
        if (from != null && to != null && usable(from) && target(to)) {
          aliases[from] = to;
        }
      }
      return Map.unmodifiable(aliases);
    }

    bool isAlias(String id) => !indexed(id) && !missing.containsKey(id);
    final aliases = readAliases(data['aliases'], indexed, usable: isAlias);
    final missingAliases = readAliases(
      data['missingAliases'],
      missing.containsKey,
      usable: (id) => isAlias(id) && !aliases.containsKey(id),
    );
    return LocalMusicRepairSnapshot._(
      Map.unmodifiable(missing),
      aliases,
      missingAliases,
      readAliases(data['playlistAliases'], indexed,
          usable: (_) => true, playlist: true),
      readAliases(data['missingPlaylistIds'], missing.containsKey,
          usable: (_) => true, playlist: true),
    );
  }

  static String? _trackId(Object? value) => _validId(value, _id);

  static String? _validId(Object? value, RegExp pattern) =>
      value is String && pattern.stringMatch(value) == value ? value : null;
}
