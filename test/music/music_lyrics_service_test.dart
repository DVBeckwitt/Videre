import 'dart:async';
import 'dart:convert';

import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_service.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _song = MusicMetadata(
  title: 'Example Artist - Example Song (Official Video) (4K Remaster)',
  artist: 'Example Artist',
  album: 'Example Album',
);

Map<String, Object?> _recordData([Map<String, Object?> changes = const {}]) => {
      'id': 21,
      'trackName': 'Example Song',
      'artistName': 'Example Artist',
      'albumName': 'Example Album',
      'duration': 180.25,
      'plainLyrics': 'Example line',
      'syncedLyrics': '[00:10.00]Example line\n[02:31.50]Example line',
      'instrumental': false,
      ...changes,
    };

http.Response _json(Object payload) => http.Response(
      jsonEncode(payload),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _record({Map<String, Object?> changes = const {}}) =>
    _json(_recordData(changes));

void main() {
  test('one exact lookup sends only public metadata and preserves synced lines',
      () async {
    final service = LrclibMusicLyricsService(createClient: () {
      return MockClient((request) async {
        expect(request.url.origin, 'https://lrclib.net');
        expect(request.url.path, '/api/get');
        expect(request.followRedirects, isFalse);
        expect(request.headers.keys, unorderedEquals(['accept', 'user-agent']));
        expect(request.url.queryParameters, {
          'track_name': 'Example Song',
          'artist_name': 'Example Artist',
          'album_name': 'Example Album',
          'duration': '180',
        });
        return _record();
      });
    });
    final lyrics = await service.load(_song, 180, isCurrent: () => true);
    expect(lyrics.kind, MusicLyricsKind.synced);
    expect(lyrics.source, 'LRCLIB');
    expect(lyrics.cues.map((cue) => cue.start.inMilliseconds), [10000, 151500]);
    expect(
        lyrics.cues.map((cue) => cue.text), ['Example line', 'Example line']);
  });

  test('uses word timing only where it fits the provider cue', () async {
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async => _record(changes: {
              'syncedLyrics': '[00:10]  <00:10>First <00:12>line\n'
                  ' Translation  \n'
                  '[02:31.50]<02:31.50>Last <03:00>line',
            })));
    final lyrics = await service.load(_song, 180, isCurrent: () => true);
    expect(lyrics.cues.map((cue) => cue.text), ['First line', 'Last line']);
    expect(lyrics.displayTextByCue, {0: '  First line\n Translation  '});
    expect(lyrics.wordsByCue.keys, [0]);
    expect(lyrics.wordsByCue[0]!.last.start, const Duration(seconds: 12));
  });

  test('applies the provider offset once to both cues and words', () async {
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async => _record(changes: {
              'syncedLyrics': '[offset:+500]\n'
                  '[00:00.100]<00:00.100>First <00:00.400>line\n'
                  '[03:00.250]Last line',
            })));
    final lyrics = await service.load(_song, 180, isCurrent: () => true);
    expect(lyrics.kind, MusicLyricsKind.synced);
    expect(lyrics.cues.map((cue) => cue.start.inMilliseconds), [-400, 179750]);
    expect(lyrics.wordsByCue[0]!.map((word) => word.start.inMilliseconds),
        [-400, -100]);
  });

  test('malformed or conflicting offsets retain readable provider lyrics',
      () async {
    for (final offset in ['[offset:broken]', '[offset:+500]\n[offset:-500]']) {
      for (final plain in ['Provider plain text', null]) {
        final service = LrclibMusicLyricsService(
            createClient: () => MockClient((_) async => _record(changes: {
                  'syncedLyrics': '$offset\n[00:10]<00:10>First line\n'
                      '[00:20]Second line',
                  'plainLyrics': plain,
                })));
        final lyrics = await service.load(_song, 180, isCurrent: () => true);
        expect(lyrics.kind, MusicLyricsKind.plain);
        expect(lyrics.text, plain ?? 'First line\nSecond line');
        expect(lyrics.wordsByCue, isEmpty);
      }
    }
  });

  test('mismatched versions and durations are unavailable', () async {
    for (final changes in [
      {'trackName': 'Example Song (Live)'},
      {'albumName': 'Unrelated Album'},
      {'duration': 183},
    ]) {
      final service = LrclibMusicLyricsService(
          createClient: () =>
              MockClient((_) async => _record(changes: changes)));
      final result = await service.load(_song, 180, isCurrent: () => true);
      expect(result.kind, MusicLyricsKind.unavailable);
    }
  });

  test('keeps plain lyrics and identifies instrumentals', () async {
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async => _record()));
    expect((await service.load(_song, null, isCurrent: () => true)).text,
        'Example line');
    final instrumental = LrclibMusicLyricsService(
        createClient: () =>
            MockClient((_) async => _record(changes: {'instrumental': true})));
    expect((await instrumental.load(_song, 180, isCurrent: () => true)).kind,
        MusicLyricsKind.instrumental);
  });

  test('long playback is still compared with the returned recording', () async {
    var length = 180;
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((request) async {
              expect(
                  request.url.queryParameters.containsKey('duration'), isFalse);
              return _record(changes: {'duration': length});
            }));
    expect((await service.load(_song, 4200, isCurrent: () => true)).kind,
        MusicLyricsKind.unavailable);
    length = 4200;
    expect((await service.load(_song, 4200, isCurrent: () => true)).kind,
        MusicLyricsKind.synced);
  });

  test('mixed malformed timing falls back to complete plain lyrics', () async {
    for (final broken in ['[00:99]Second line', '[00:15][00:99]Second line']) {
      final service = LrclibMusicLyricsService(
          createClient: () => MockClient((_) async => _record(changes: {
                'syncedLyrics': '[00:10]First line\n$broken',
                'plainLyrics': 'First line\nSecond line'
              })));
      final lyrics = await service.load(_song, 180, isCurrent: () => true);
      expect(lyrics.kind, MusicLyricsKind.plain);
      expect(lyrics.text, 'First line\nSecond line');
    }
  });

  test('large repeated lines retain every occurrence in timed and plain views',
      () async {
    final words = 'a' * 2000;
    final tags = '[00:01]' * 200;
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async => _record(
            changes: {'syncedLyrics': '$tags$words', 'plainLyrics': null})));
    final timed = await service.load(_song, 180, isCurrent: () => true);
    expect(timed.kind, MusicLyricsKind.synced);
    final plain = await service.load(_song, null, isCurrent: () => true);
    expect(plain.kind, MusicLyricsKind.plain);
    expect(plain.text, isNull);
    for (final result in [timed, plain]) {
      expect(result.cues, hasLength(200));
      expect(result.cues.map((cue) => cue.text), everyElement(words));
    }
  });

  test('malformed records report a retryable provider failure', () async {
    for (final changes in [
      {'id': null},
      {'trackName': ''},
      {'artistName': 123},
      {'duration': '180'},
      {'instrumental': 'false'},
    ]) {
      final service = LrclibMusicLyricsService(
          createClient: () =>
              MockClient((_) async => _record(changes: changes)));
      await expectLater(service.load(_song, 180, isCurrent: () => true),
          throwsA(isA<MusicLyricsRequestException>()));
    }
  });

  test('disabled or stale sessions never start a lookup or display a result',
      () async {
    var calls = 0;
    var active = false;
    final service = LrclibMusicLyricsService(createClient: () {
      return MockClient((_) async {
        calls++;
        active = false;
        return _record();
      });
    });
    expect((await service.load(_song, 180, isCurrent: () => active)).kind,
        MusicLyricsKind.unavailable);
    expect(calls, 0);
    active = true;
    expect((await service.load(_song, 180, isCurrent: () => active)).kind,
        MusicLyricsKind.unavailable);
    expect(calls, 1);
  });

  test('retiring a held lookup lets the next current song request lyrics',
      () async {
    final firstResponse = Completer<http.Response>();
    final firstStarted = Completer<void>();
    final retired = Completer<void>();
    final skipped = Completer<void>();
    var calls = 0;
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async {
              calls++;
              if (calls == 1) {
                firstStarted.complete();
                return firstResponse.future;
              }
              return _record();
            }));

    final first = service.load(_song, 180,
        isCurrent: () => !retired.isCompleted, retired: retired.future);
    await firstStarted.future;
    final superseded = service.load(_song, 180,
        isCurrent: () => !skipped.isCompleted, retired: skipped.future);
    final next = service.load(_song, 180,
        isCurrent: () => true, retired: Completer<void>().future);
    expect(calls, 1);
    skipped.complete();
    retired.complete();
    expect((await first).kind, MusicLyricsKind.unavailable);
    expect((await superseded).kind, MusicLyricsKind.unavailable);
    expect((await next).kind, MusicLyricsKind.synced);
    expect(calls, 2);
    firstResponse.complete(_record());
  });

  test('429 respects provider cooldown and 404 is a normal miss', () async {
    var now = DateTime(2026, 11, 18);
    var calls = 0;
    final service = LrclibMusicLyricsService(
        now: () => now,
        createClient: () => MockClient((_) async {
              calls++;
              return calls == 1
                  ? http.Response('', 429, headers: {'retry-after': '10'})
                  : http.Response('', 404);
            }));
    final failed = throwsA(isA<MusicLyricsRequestException>());
    await expectLater(service.load(_song, 180, isCurrent: () => true), failed);
    await expectLater(service.load(_song, 180, isCurrent: () => true), failed);
    expect(calls, 1);
    now = now.add(const Duration(seconds: 10));
    final missing = await service.load(_song, 180, isCurrent: () => true);
    expect(missing.kind, MusicLyricsKind.unavailable);
    expect(calls, 2);
  });

  test('an invalid Retry-After still suppresses immediate retries', () async {
    var calls = 0;
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async {
              calls++;
              return http.Response('', 503, headers: {'retry-after': 'soon'});
            }));
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(service.load(_song, 180, isCurrent: () => true),
          throwsA(isA<MusicLyricsRequestException>()));
    }
    expect(calls, 1);
  });

  test('manual search returns preview-ready alternatives with their metadata',
      () async {
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((request) async {
              expect(request.url.origin, 'https://lrclib.net');
              expect(request.url.path, '/api/search');
              expect(request.followRedirects, isFalse);
              expect(request.headers.keys,
                  unorderedEquals(['accept', 'user-agent']));
              expect(request.url.queryParameters, {
                'track_name': 'Changed Title',
                'artist_name': 'Changed Artist',
              });
              return _json([
                _recordData(),
                _recordData({
                  'id': 22,
                  'trackName': 'Example Song (Live)',
                  'albumName': 'Live Album',
                  'duration': 186.5,
                  'plainLyrics': null,
                }),
                _recordData({'id': 23, 'instrumental': true}),
              ]);
            }));
    final matches = await service.search(
      trackName: ' Changed  Title ',
      artistName: 'Changed Artist',
      albumName: '',
      durationSeconds: 180,
      isCurrent: () => true,
    );
    expect(matches.map((match) => match.id), [21, 22, 23]);
    expect(matches.first.lyrics.kind, MusicLyricsKind.synced);
    final alternate = matches[1];
    expect(alternate.trackName, 'Example Song (Live)');
    expect(alternate.artistName, 'Example Artist');
    expect(alternate.albumName, 'Live Album');
    expect(alternate.duration, const Duration(milliseconds: 186500));
    expect(alternate.lyrics.kind, MusicLyricsKind.plain);
    expect(alternate.lyrics.text, 'Example line\nExample line');
    expect(alternate.lyrics.source, 'LRCLIB');
    expect(matches[2].lyrics.kind, MusicLyricsKind.instrumental);
  });

  test('manual search bounds and deduplicates usable records', () async {
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((request) async {
              expect(request.url.queryParameters, {
                'track_name': 'Example Song',
                'album_name': 'Example Album',
              });
              return _json([
                _recordData({'id': null}),
                _recordData(
                    {'id': 1, 'syncedLyrics': null, 'plainLyrics': null}),
                _recordData({'id': 2, 'duration': 1e100}),
                _recordData(),
                _recordData(),
                for (var id = 30; id < 60; id++) _recordData({'id': id}),
              ]);
            }));
    final matches = await service.search(
      trackName: 'Example Song',
      artistName: '',
      albumName: 'Example Album',
      durationSeconds: null,
      isCurrent: () => true,
    );
    expect(matches.map((match) => match.id),
        [21, ...List.generate(15, (i) => i + 30)]);
    expect(matches.every((match) => match.lyrics.kind == MusicLyricsKind.plain),
        isTrue);
  });

  test('manual search suppresses stale responses and sends only valid queries',
      () async {
    var active = false;
    var calls = 0;
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async {
              calls++;
              active = false;
              return _json([_recordData()]);
            }));
    Future<void> expectEmpty(String title) async {
      expect(
          await service.search(
            trackName: title,
            artistName: '',
            albumName: '',
            durationSeconds: 180,
            isCurrent: () => active,
          ),
          isEmpty);
    }

    await expectEmpty('Example Song');
    active = true;
    await expectEmpty('a' * 321);
    expect(calls, 0);
    await expectEmpty('Example Song');
    expect(calls, 1);
  });

  test('manual and automatic lookups share provider cooldown', () async {
    var calls = 0;
    final service = LrclibMusicLyricsService(
        createClient: () => MockClient((_) async {
              calls++;
              return http.Response('', 429, headers: {'retry-after': '10'});
            }));
    final failed = throwsA(isA<MusicLyricsRequestException>());
    await expectLater(
        service.search(
          trackName: 'Example Song',
          artistName: 'Example Artist',
          albumName: '',
          durationSeconds: 180,
          isCurrent: () => true,
        ),
        failed);
    await expectLater(service.load(_song, 180, isCurrent: () => true), failed);
    expect(calls, 1);
  });
}
