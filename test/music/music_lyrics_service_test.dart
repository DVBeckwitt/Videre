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

http.Response _record({Map<String, Object?> changes = const {}}) =>
    http.Response(
      jsonEncode({
        'id': 21,
        'trackName': 'Example Song',
        'artistName': 'Example Artist',
        'albumName': 'Example Album',
        'duration': 180.25,
        'plainLyrics': 'Example line',
        'syncedLyrics': '[00:10.00]Example line\n[02:31.50]Example line',
        'instrumental': false,
        ...changes,
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

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
}
