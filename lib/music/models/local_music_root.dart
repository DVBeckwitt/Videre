import 'local_music_track.dart';

/// An Android source approved for the device music library.
class LocalMusicRoot {
  const LocalMusicRoot({
    required this.uri,
    required this.name,
    required this.selectionId,
    this.needsReapproval = false,
    this.isDocumentProvider = false,
  });

  final Uri uri;
  final String name;
  final String? selectionId;
  final bool needsReapproval;
  final bool isDocumentProvider;

  bool get isSystem => uri == LocalMusicTrack.systemSource;
}
