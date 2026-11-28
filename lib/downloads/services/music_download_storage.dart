import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/downloaded_video.dart';
import 'download_storage.dart';

typedef MusicDownloadStorageUsage = ({int bytes, bool incomplete});

/// Measures files belonging to the supplied profile's Music download jobs.
/// No directory, download, or provider document is created by this lookup.
Future<MusicDownloadStorageUsage> measureMusicDownloadStorage(
    Iterable<DownloadedVideo> downloads,
    {required String profileId,
    DownloadStorage? storage}) async {
  if (!DownloadedVideo.isSafeFileId(profileId)) {
    return (bytes: 0, incomplete: false);
  }
  final extensions = <String, Set<String>>{};
  final documents = <String, Set<String>>{};
  var bytes = 0;
  var incomplete = false;

  void count(int? length) {
    if (length == null || length < 0 || length > 0x7fffffffffffffff - bytes) {
      incomplete = true;
    } else {
      bytes += length;
    }
  }

  void document(String uri, String? folder) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || parsed.scheme != 'content' || parsed.host.isEmpty) {
      incomplete = true;
      return;
    }
    final grants = documents.putIfAbsent(uri, () => <String>{});
    if (folder != null && folder.isNotEmpty) grants.add(folder);
  }

  // Snapshot before any await. Completion, pause, or a profile switch can
  // change the UI's input while filesystem and provider queries are pending.
  for (final row in downloads) {
    if (row.profileId != profileId ||
        !row.audioOnly ||
        row.musicMetadata == null ||
        !DownloadedVideo.isSafeFileId(row.videoId)) {
      continue;
    }
    extensions.putIfAbsent(row.videoId, () => <String>{}).add(row.extension);
    if (row.storageUri case final uri?) document(uri, row.folderUri);
    for (final copy in [row.exportedMusic, row.incompleteMusicEdit]) {
      if (copy != null && !copy.complete) document(copy.uri, copy.folder);
    }
  }
  if (extensions.isEmpty) return (bytes: 0, incomplete: false);

  Future<void> privateFiles() async {
    try {
      var folder = await getApplicationDocumentsDirectory();
      for (final segment in privateDownloadFolderSegments(profileId)) {
        folder = Directory(p.join(folder.path, segment));
        await _requireDirectory(folder);
      }
      for (final row in extensions.entries) {
        final prefix = p.join(folder.path, row.key);
        final paths = {
          for (final extension in row.value) '$prefix.$extension',
          '$prefix.jpg',
          '$prefix.jpg.part',
          '$prefix.vtt',
          for (final suffix in downloadStagingSuffixes) '$prefix.webm$suffix',
        };
        for (final size in await Future.wait(paths.map(_fileSize))) {
          count(size);
        }
        final covers = Directory('$prefix.song-covers');
        try {
          await _requireDirectory(covers);
          await for (final item in covers.list(followLinks: false)) {
            if (item is File) count(await _fileSize(item.path));
          }
        } on PathNotFoundException {
          // Artwork is optional and can disappear during download cleanup.
        } on FileSystemException {
          incomplete = true;
        }
      }
    } on PathNotFoundException {
      // A profile need never have created a private download directory.
    } on Exception {
      incomplete = true;
    }
  }

  final provider = storage ?? DownloadStorage();
  final pending = documents.entries.iterator;
  Future<void> measureDocuments() async {
    while (pending.moveNext()) {
      final document = pending.current;
      int? size;
      for (final grant in document.value) {
        try {
          size = await provider
              .documentSize(document.key, grant)
              .timeout(const Duration(seconds: 3));
          if (size != null && size >= 0) break;
        } on TimeoutException {
          // A slow provider may still hold its native query. Retire this
          // worker so stalled queries cannot accumulate for a long list.
          incomplete = true;
          return;
        } on Exception {
          // Another recorded grant for the same URI may still authorize it.
        }
      }
      count(size);
    }
  }

  await Future.wait([
    privateFiles(),
    for (var i = 0; i < 4 && i < documents.length; i++) measureDocuments(),
  ]);
  return (bytes: bytes, incomplete: incomplete);
}

/// Dart's no-follow type query reports notFound for lookup errors as well.
/// The second lookup distinguishes a missing directory from denied access.
Future<void> _requireDirectory(Directory folder) async {
  final type = await FileSystemEntity.type(folder.path, followLinks: false);
  if (type == FileSystemEntityType.directory) return;
  if (type == FileSystemEntityType.notFound) {
    await folder.resolveSymbolicLinks();
  }
  throw FileSystemException(
      'Expected a private download directory', folder.path);
}

Future<int?> _fileSize(String path) async {
  try {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      return null;
    }
    return await File(path).length();
  } on PathNotFoundException {
    return 0;
  } on FileSystemException {
    return null;
  }
}
