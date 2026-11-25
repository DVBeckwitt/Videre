import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/services/music_download_storage.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _song = DownloadedVideo(
    profileId: 'person-a',
    videoId: 'song',
    title: 'Song',
    musicMetadata: MusicMetadata(title: 'Song', artist: 'Artist'),
    quality: 'highest-audio',
    audioOnly: true,
    musicFormat: MusicDownloadFormat.mp3,
    lengthSeconds: 30);

const _folder = 'content://documents/tree/primary%3AVidere';
String _document(String name) => '$_folder/document/primary%3AVidere%2F$name';

Future<void> _write(String path, int bytes) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(List.filled(bytes, 1));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const storage = MethodChannel('videre/download_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('videre-music-storage-');
    messenger.setMockMethodCallHandler(
        pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    messenger.setMockMethodCallHandler(storage, null);
    await documents.delete(recursive: true);
  });

  test(
      'counts owned private files for completed, pending and failed Music jobs once',
      () async {
    final completed = _song.copyWith(downloadComplete: true);
    final pending = _song.copyWith(videoId: 'pending');
    final failed = _song.copyWith(videoId: 'failed', downloadFailed: true);
    final covers = await completed.songCoverDirectory;
    final staging = await pending.stagingPath;
    final failedStaging = await failed.stagingPath;
    final thumbnail = await completed.thumbnailPath;
    final known = {
      await completed.downloadPath: 12,
      '$staging.audio.part': 3,
      '$staging.audio.part.identity': 4,
      '$failedStaging.mux.mp3': 5,
      '$failedStaging.export-input.part': 1,
      await completed.subtitlePath: 2,
      thumbnail: 6,
      '$thumbnail.part': 7,
      p.join(covers.path, '${'a' * 64}.jpg'): 8,
      p.join(covers.path, 'stock-${'b' * 64}.jpg.part'): 9,
    };
    for (final entry in known.entries) {
      await _write(entry.key, entry.value);
    }

    final otherProfile = completed.copyWith(profileId: 'default');
    final video = completed.copyWith(videoId: 'video', audioOnly: false);
    final ordinaryAudio =
        completed.copyWith(videoId: 'audio', musicMetadata: null);
    for (final unrelated in [
      await otherProfile.downloadPath,
      await video.downloadPath,
      await ordinaryAudio.downloadPath,
      p.join(covers.path, 'unrelated', 'nested.jpg'),
      p.join(covers.parent.path, 'untracked.mp3'),
      p.join(documents.path, 'cache', 'music.mp3'),
      '$staging.unrelated',
    ]) {
      await _write(unrelated, 100);
    }

    final rows = [
      completed,
      completed.copyWith(queueEntryId: 'song#1'),
      pending,
      failed,
      otherProfile,
      video,
      ordinaryAudio
    ];
    expect(await measureMusicDownloadStorage(rows, profileId: 'person-a'),
        (bytes: 57, incomplete: false));
    expect(await measureMusicDownloadStorage(rows, profileId: 'default'),
        (bytes: 100, incomplete: false));
    expect(await File('$staging.audio.part').length(), 3);
    expect(await File('$thumbnail.part').length(), 7);
  });

  test('missing private files do not create profile or download directories',
      () async {
    expect(await measureMusicDownloadStorage([_song], profileId: 'person-a'),
        (bytes: 0, incomplete: false));
    expect(await documents.list().toList(), isEmpty);
  });

  test(
      'counts each owned external document once and leaves completed exports independent',
      () async {
    final primary = _document('primary.mp3');
    final unfinished = _document('writing.mp3');
    final userCopy = _document('export.mp3');
    final sizes = {primary: 13, unfinished: 7};
    final calls = <(String, String)>[];
    messenger.setMockMethodCallHandler(storage, (call) async {
      expect(call.method, 'documentSize');
      final uri = call.arguments['uri'] as String;
      calls.add((uri, call.arguments['folderUri'] as String));
      return sizes[uri];
    });
    final first = _song.copyWith(
        folderUri: _folder,
        storageUri: primary,
        downloadComplete: true,
        exportedMusic: ExportedMusicCopy(
            _folder, userCopy, MusicDownloadFormat.mp3,
            complete: true));
    final failed = _song.copyWith(
        videoId: 'failed',
        downloadFailed: true,
        folderUri: _folder,
        storageUri: primary,
        exportedMusic:
            ExportedMusicCopy(_folder, unfinished, MusicDownloadFormat.mp3));
    final excluded = first.copyWith(
        storageUri: _document('excluded.mp3'), exportedMusic: null);
    final usage = await measureMusicDownloadStorage([
      first,
      failed,
      failed,
      excluded.copyWith(profileId: 'person-b'),
      excluded.copyWith(videoId: '../outside'),
      excluded.copyWith(videoId: 'device:track'),
      excluded.copyWith(audioOnly: false),
      excluded.copyWith(musicMetadata: null),
    ], profileId: 'person-a');
    expect(usage, (bytes: 20, incomplete: false));
    expect(calls, unorderedEquals([(primary, _folder), (unfinished, _folder)]));
    expect(await documents.list().toList(), isEmpty);
  });

  test('unknown or inaccessible documents keep the known byte total', () async {
    final calls = <String>[];
    final missing = _document('missing');
    final unknown = _document('unknown');
    final denied = _document('denied');
    final noFolder = _document('no-folder');
    messenger.setMockMethodCallHandler(storage, (call) async {
      expect(call.method, 'documentSize');
      final uri = call.arguments['uri'] as String;
      calls.add(uri);
      if (uri == denied) throw PlatformException(code: 'DOWNLOAD_STORAGE');
      return uri == missing ? 0 : null;
    });
    final confirmedMissing = _song.copyWith(
        videoId: 'missing', folderUri: _folder, storageUri: missing);
    expect(
        await measureMusicDownloadStorage([confirmedMissing],
            profileId: 'person-a'),
        (bytes: 0, incomplete: false));
    calls.clear();
    await _write(await _song.downloadPath, 11);
    final usage = await measureMusicDownloadStorage([
      _song,
      confirmedMissing,
      _song.copyWith(
          videoId: 'unknown', folderUri: _folder, storageUri: unknown),
      _song.copyWith(videoId: 'denied', folderUri: _folder, storageUri: denied),
      _song.copyWith(videoId: 'no-folder', storageUri: noFolder),
    ], profileId: 'person-a');
    expect(usage, (bytes: 11, incomplete: true));
    expect(calls, unorderedEquals([missing, unknown, denied]));
  });

  test(
      'negative sizes cannot reduce known bytes and overflowing totals stay representable',
      () async {
    final first =
        _song.copyWith(folderUri: _folder, storageUri: _document('first'));
    final second = _song.copyWith(
        videoId: 'second', folderUri: _folder, storageUri: _document('second'));
    var firstSize = 23;
    var secondSize = -7;
    messenger.setMockMethodCallHandler(
        storage,
        (call) async =>
            call.arguments['uri'] == first.storageUri ? firstSize : secondSize);
    expect(
        await measureMusicDownloadStorage([first, second],
            profileId: 'person-a'),
        (bytes: 23, incomplete: true));

    const maximum = 0x7fffffffffffffff;
    firstSize = maximum;
    secondSize = maximum;
    expect(
        await measureMusicDownloadStorage([first, second],
            profileId: 'person-a'),
        (bytes: maximum, incomplete: true));
  });

  testWidgets(
      'a stalled document times out while responsive bytes remain available',
      (tester) async {
    final stalled =
        _song.copyWith(folderUri: _folder, storageUri: _document('stalled'));
    final ready = _song.copyWith(
        videoId: 'ready', folderUri: _folder, storageUri: _document('ready'));
    final gate = Completer<int?>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(storage, (call) async {
      final uri = call.arguments['uri'] as String;
      calls.add(uri);
      if (uri == stalled.storageUri) return gate.future;
      return 41;
    });
    // The fixture has no private files. Keep real filesystem I/O out of the
    // widget-test clock so advancing it controls just the provider timeout.
    final measurement = IOOverrides.runZoned(
      () =>
          measureMusicDownloadStorage([stalled, ready], profileId: 'person-a'),
      fseGetType: (path, _) async =>
          throw PathNotFoundException(path, const OSError('Missing', 2)),
    );
    MusicDownloadStorageUsage? result;
    unawaited(measurement.then((usage) {
      result = usage;
    }));
    await tester.pump();
    expect(calls, unorderedEquals([stalled.storageUri, ready.storageUri]));
    expect(result, isNull);
    await tester.pump(const Duration(minutes: 1));
    expect(result, (bytes: 41, incomplete: true));
    gate.complete(100);
    await tester.pump();
    expect(result, (bytes: 41, incomplete: true));
  });
}
