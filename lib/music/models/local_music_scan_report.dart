import 'local_music_root.dart';

enum LocalMusicSkipReason { playlist, unsupportedType, missingDetails, unknown }

class LocalMusicSkippedFile {
  const LocalMusicSkippedFile({required this.name, required this.reason});

  final String? name;
  final LocalMusicSkipReason reason;

  static LocalMusicSkippedFile? _fromDocument(Object? document) {
    if (document is! Map) return null;
    final name = document['name'];
    final reason = document['reason'];
    if (reason is! String) return null;
    return LocalMusicSkippedFile(
      name:
          name is String && name.isNotEmpty && name.length <= 200 ? name : null,
      reason: switch (reason) {
        'playlist' => LocalMusicSkipReason.playlist,
        'unsupportedType' => LocalMusicSkipReason.unsupportedType,
        'missingDetails' => LocalMusicSkipReason.missingDetails,
        _ => LocalMusicSkipReason.unknown,
      },
    );
  }
}

class LocalMusicRootScanReport {
  LocalMusicRootScanReport._(this.root, this.files, this.skippedCount);

  final LocalMusicRoot root;
  final List<LocalMusicSkippedFile> files;
  final int skippedCount;

  static LocalMusicRootScanReport? fromResult(
      LocalMusicRoot root, Object? result) {
    if (result is! Map) return null;
    final documents = result['skippedFiles'];
    final count = result['skippedCount'];
    if (documents is! List || count is! int || count < documents.length) {
      return null;
    }
    return LocalMusicRootScanReport._(
      root,
      List.unmodifiable(documents
          .take(100)
          .map(LocalMusicSkippedFile._fromDocument)
          .nonNulls),
      count,
    );
  }
}

class LocalMusicScanReport {
  LocalMusicScanReport(
      {required Iterable<LocalMusicRootScanReport> locations,
      required this.partial})
      : locations = List.unmodifiable(locations);

  final List<LocalMusicRootScanReport> locations;
  final bool partial;
}
