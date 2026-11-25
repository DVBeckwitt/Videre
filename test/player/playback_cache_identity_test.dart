import 'dart:convert';

import 'package:clipious/player/models/playback_cache_identity.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/format_stream.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

const _server =
    Server(url: 'https://inv.example', profileId: 'person-a', id: 'account-a');
const _url = 'https://inv.example/videoplayback?itag=140&sig=old';

AdaptiveFormat _audio({
  String url = _url,
  String itag = '140',
  String clen = '12345',
  String lmt = '1700000000000',
  String track = 'en.1',
  String type = 'audio/mp4; codecs="mp4a.40.2"',
}) =>
    AdaptiveFormat(null, '128000', null, url, itag, type, clen, lmt,
        'RECTANGULAR', 'm4a', 'aac', null, null,
        audioTrack: AudioTrack(id: track, displayName: 'English'));

Map<String, Object?>? _identity({
  Video? video,
  Server server = _server,
  String sourceUrl = _url,
  String sessionId = 'session-a',
}) =>
    playbackCacheIdentity(
        video: video ?? Video(videoId: 'song', adaptiveFormats: [_audio()]),
        server: server,
        sourceUrl: sourceUrl,
        sessionId: sessionId);

Map<String, Object?> _resource(Map<String, Object?> payload, String url) =>
    (payload['resources'] as List<Map<String, Object?>>)
        .singleWhere((resource) => resource['url'] == url);

void main() {
  test('only admitted immutable progressive Music audio carries song metadata',
      () {
    final audio = _audio();
    final video = Video(
        videoId: 'song',
        lengthSeconds: 180,
        musicMetadata: const MusicMetadata(title: 'Song', artist: 'Artist'),
        adaptiveFormats: [audio]);
    Map<String, Object?>? identity(Video video, AdaptiveFormat? format,
            {bool companions = false}) =>
        playbackCacheIdentity(
            video: video,
            server: _server,
            sourceUrl: _url,
            sessionId: 'session-a',
            mediaCompanions: companions,
            progressiveMusicAudio: format);

    expect(identity(video, audio)!['musicSong'], {
      'title': 'Song',
      'artist': 'Artist',
      'lengthSeconds': 180,
      'byteLength': 12345,
    });
    expect(identity(video, null)!['musicSong'], isNull);
    expect(identity(video, audio, companions: true)!['musicSong'], isNull);
    expect(identity(video.copyWith(isUpcoming: true), audio)!['musicSong'],
        isNull);
    final partial = _audio(clen: '');
    expect(
        identity(
            video.copyWith(adaptiveFormats: [partial]), partial)!['musicSong'],
        isNull);
  });

  test('signed URL refresh preserves immutable representation identity', () {
    const fresh = 'https://inv.example/videoplayback?itag=140&sig=new';
    final old = _resource(_identity()!, _url);
    final next = _resource(
        _identity(
            video:
                Video(videoId: 'song', adaptiveFormats: [_audio(url: fresh)]),
            sourceUrl: fresh,
            sessionId: 'session-b')!,
        fresh);
    expect(old['persistent'], isTrue);
    expect(next['persistent'], isTrue);
    expect(next['key'], old['key']);
    expect(next['url'], fresh);
    expect(next['key'], isNot(contains('sig')));
  });

  test('representation revisions and language tracks cannot share bytes', () {
    final original = _resource(_identity()!, _url)['key'];
    for (final format in [
      _audio(itag: '141'),
      _audio(clen: '12346'),
      _audio(lmt: '1700000000001'),
      _audio(track: 'es.1'),
      _audio(type: 'audio/webm; codecs="opus"'),
    ]) {
      final changed = _resource(
          _identity(video: Video(videoId: 'song', adaptiveFormats: [format]))!,
          _url);
      expect(changed['key'], isNot(original));
    }
  });

  test('scope retains profile, account, instance and content identity', () {
    final original = _identity()!;
    expect(original, containsPair('version', 1));
    expect(original, containsPair('profileId', 'person-a'));
    expect(original, containsPair('accountId', 'account-a'));
    expect(original, containsPair('origin', 'https://inv.example'));
    expect(original, containsPair('contentId', 'song'));
    expect(
        _identity(
            server: _server.copyWith(profileId: 'person-b'))!['profileId'],
        isNot(original['profileId']));
    expect(_identity(server: _server.copyWith(id: 'account-b'))!['accountId'],
        isNot(original['accountId']));
    expect(_identity(video: const Video(videoId: 'other'))!['contentId'],
        isNot(original['contentId']));
    const otherUrl = 'https://other.example/videoplayback';
    expect(
        _identity(
            server: _server.copyWith(url: 'https://other.example'),
            sourceUrl: otherUrl)!['origin'],
        isNot(original['origin']));
  });

  test('missing immutable identity is isolated by session and resource', () {
    const other = 'https://inv.example/videoplayback?itag=251&sig=other';
    final video = Video(videoId: 'song', adaptiveFormats: [
      _audio(clen: ''),
      _audio(url: other, clen: ''),
    ]);
    final first = _identity(video: video)!;
    final old = _resource(first, _url);
    expect(old['persistent'], isFalse);
    expect(old['key'], isNot(_resource(first, other)['key']));
    final next =
        _resource(_identity(video: video, sessionId: 'session-b')!, _url);
    expect(next['key'], isNot(old['key']));
  });

  test('invalid numeric identity never becomes persistent', () {
    for (final format in [
      _audio(clen: '0'),
      _audio(clen: '-1'),
      _audio(clen: 'NaN'),
      _audio(lmt: '0'),
      _audio(lmt: ''),
      _audio(itag: ''),
      _audio(itag: 'secret-token'),
    ]) {
      final resource = _resource(
          _identity(video: Video(videoId: 'song', adaptiveFormats: [format]))!,
          _url);
      expect(resource['persistent'], isFalse);
    }
  });

  test('combined sources use only unambiguous numeric URL identity', () {
    const url =
        'https://inv.example/videoplayback?itag=18&clen=900&lmt=123&sig=x';
    final video = Video(videoId: 'song', formatStreams: [
      FormatStream(
          url, '18', 'video/mp4', 'medium', 'mp4', 'h264', null, null, null),
    ]);
    final resource = _resource(_identity(video: video, sourceUrl: url)!, url);
    expect(resource['persistent'], isTrue);
    expect(resource['key'], isNot(contains('sig')));
  });

  test('different audio tracks in combined sources cannot reuse bytes', () {
    const english =
        'https://inv.example/videoplayback?itag=18&clen=900&lmt=123&sig=x';
    const french =
        'https://inv.example/videoplayback?itag=18&clen=900&lmt=123&sig=y';
    final video = Video(videoId: 'song', formatStreams: [
      FormatStream(
          english, '18', 'video/mp4', 'medium', 'mp4', 'h264', null, null, null,
          audioTrack: const AudioTrack(id: 'en', displayName: 'English')),
      FormatStream(
          french, '18', 'video/mp4', 'medium', 'mp4', 'h264', null, null, null,
          audioTrack: const AudioTrack(id: 'fr', displayName: 'French')),
    ]);
    final identity = _identity(video: video, sourceUrl: english)!;
    final first = _resource(identity, english);
    final second = _resource(identity, french);
    expect(first['persistent'], isTrue);
    expect(second['persistent'], isTrue);
    expect(first['key'], isNot(second['key']));
  });

  test('duplicate and conflicting URL identity remains session-only', () {
    for (final query in [
      'itag=18&clen=900&clen=901&lmt=123',
      'itag=19&clen=900&lmt=123',
      'itag=18&clen=900&lmt=123&range=10-20',
    ]) {
      final url = 'https://inv.example/videoplayback?$query';
      final video = Video(videoId: 'song', formatStreams: [
        FormatStream(
            url, '18', 'video/mp4', 'medium', 'mp4', 'h264', null, null, null),
      ]);
      expect(
          _resource(
              _identity(video: video, sourceUrl: url)!, url)['persistent'],
          isFalse);
    }
  });

  test('official media is mapped only onto its selected Invidious route', () {
    const raw = 'https://rr1.googlevideo.com/videoplayback?itag=140&sig=x';
    const proxied =
        'https://inv.example/videoplayback?itag=140&sig=x&host=rr1.googlevideo.com';
    final payload = _identity(
        video: Video(videoId: 'song', adaptiveFormats: [_audio(url: raw)]),
        sourceUrl: proxied)!;
    expect(_resource(payload, proxied)['persistent'], isTrue);
    expect(
        (payload['resources'] as List).every((resource) =>
            Uri.parse((resource as Map)['url'] as String).origin ==
            _server.url),
        isTrue);
    expect(_identity(sourceUrl: raw), isNull);
  });

  test(
      'invalid destination, credentials and live sources cannot opt into cache',
      () {
    for (final url in [
      'https://elsewhere.example/video',
      'http://inv.example/video',
      'https://inv.example:8443/video',
      'https://user:password@inv.example/video',
      'file:///tmp/video',
      'not a URL',
    ]) {
      expect(_identity(sourceUrl: url), isNull);
    }
    expect(
        _identity(video: const Video(videoId: 'live', liveNow: true)), isNull);
    expect(_identity(sessionId: ''), isNull);
    expect(
        _identity(
            server: const Server(url: 'https://www.youtube.com'),
            sourceUrl: 'https://www.youtube.com/watch?v=song'),
        isNull);
  });

  test('scope and keys never copy headers or signed query values', () {
    final payload = _identity(
        server: _server.copyWith(
            authToken: 'auth-secret',
            sidCookie: 'cookie-secret',
            customHeaders: {'X-Key': 'header-secret'}))!;
    final forDisk = Map<String, Object?>.from(payload)
      ..['resources'] = (payload['resources'] as List<Map<String, Object?>>)
          .map((resource) => Map<String, Object?>.from(resource)..remove('url'))
          .toList();
    final text = jsonEncode(forDisk);
    for (final secret in [
      'auth-secret',
      'cookie-secret',
      'header-secret',
      'sig='
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('signed manifests are marked for native cache bypass', () {
    for (final url in [
      'https://inv.example/custom-dash?sig=temporary&local=true',
      'https://inv.example/api/manifest/hls_playlist/id/song?sig=temporary',
      'https://inv.example/stream.mpd?sig=temporary',
      'https://inv.example/stream.m3u8?sig=temporary',
    ]) {
      final payload = _identity(
          video: Video(
              videoId: 'song',
              dashUrl: 'https://inv.example/custom-dash?sig=temporary',
              adaptiveFormats: [_audio()]),
          sourceUrl: url)!;
      final source = _resource(payload, url);
      expect(source['manifest'], isTrue);
      expect(source['persistent'], isFalse);
      expect(_resource(payload, _url)['manifest'], isFalse);
      expect(_resource(payload, _url)['persistent'], isTrue);
    }
  });

  test('adaptive child caching requires explicit non-live metadata', () {
    const manifest = 'https://inv.example/stream.m3u8';
    final unknown = _identity(
        video: const Video(videoId: 'song', hlsUrl: manifest),
        sourceUrl: manifest)!;
    expect(unknown['adaptiveVod'], isFalse);
    final vod = _identity(
        video: const Video(videoId: 'song', hlsUrl: manifest, liveNow: false),
        sourceUrl: manifest)!;
    expect(vod['adaptiveVod'], isTrue);
    expect(_resource(vod, manifest)['manifest'], isTrue);
    expect(
        _identity(
            video:
                const Video(videoId: 'song', hlsUrl: manifest, liveNow: true),
            sourceUrl: manifest),
        isNull);
  });

  test('query language and partial-range resources retain distinct keys', () {
    final urls = [
      'https://inv.example/videoplayback?lang=en',
      'https://inv.example/videoplayback?lang=es',
      'https://inv.example/videoplayback?range=0-99',
      'https://inv.example/videoplayback?range=100-199',
    ];
    final payload = _identity(
        video: Video(
            videoId: 'song',
            adaptiveFormats: urls.map((url) => _audio(url: url)).toList()))!;
    final resources = urls.map((url) => _resource(payload, url)).toList();
    expect(resources.map((resource) => resource['key']).toSet(), hasLength(4));
    expect(
        resources.take(2).every((resource) => resource['persistent'] == true),
        isTrue);
    expect(
        resources.skip(2).every((resource) => resource['persistent'] == false),
        isTrue);
  });

  test('malformed query and conflicting metadata cannot crash admission', () {
    const malformed = 'https://inv.example/videoplayback?itag=%XX';
    const invalidUtf8 = 'https://inv.example/videoplayback?itag=%C3';
    final payload = _identity(
        video: Video(videoId: 'song', adaptiveFormats: [
      _audio(),
      _audio(lmt: '1700000000001'),
      _audio(url: malformed),
      _audio(url: invalidUtf8),
    ]))!;
    expect(_resource(payload, _url)['persistent'], isFalse);
    expect(_resource(payload, malformed)['persistent'], isFalse);
    expect(_resource(payload, invalidUtf8)['persistent'], isFalse);
  });

  test('remote format lists cannot exceed the native resource bound', () {
    final formats = List.generate(600,
        (index) => _audio(url: 'https://inv.example/videoplayback?id=$index'));
    for (final source in [_url, formats.last.url]) {
      final payload = _identity(
          video: Video(videoId: 'song', adaptiveFormats: formats),
          sourceUrl: source)!;
      expect(payload['resources'] as List, hasLength(512));
      expect(_resource(payload, source)['persistent'], isFalse);
    }
  });
}
