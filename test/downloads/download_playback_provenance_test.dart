import 'dart:convert';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/download_playback_provenance.dart';
import 'package:clipious/player/models/playback_cache_identity.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter_test/flutter_test.dart';

const _server =
    Server(url: 'https://inv.example', profileId: 'person-a', id: 'account-a');
final _hash = List.filled(64, 'a').join();

AdaptiveFormat _audio({
  String url = 'https://inv.example/videoplayback?itag=251&sig=old',
  String itag = '251',
  String clen = '12345',
  String lmt = '1700000000000',
  String type = 'audio/webm; codecs="opus"',
  String? track = 'en.1',
  bool defaultTrack = true,
}) =>
    AdaptiveFormat(null, '128000', null, url, itag, type, clen, lmt,
        'RECTANGULAR', 'webm', 'opus', null, null,
        audioTrack: track == null
            ? null
            : AudioTrack(
                id: track,
                displayName: 'English',
                audioIsDefault: defaultTrack));

AdaptiveFormat _video({
  String url = 'https://inv.example/videoplayback?itag=248&sig=old',
  String itag = '248',
  String clen = '54321',
  String lmt = '1700000000000',
}) =>
    AdaptiveFormat(null, '1000000', null, url, itag, 'video/webm; codecs="vp9"',
        clen, lmt, 'RECTANGULAR', 'webm', 'vp9', '1080p', '1080');

Video _content({
  String id = 'song',
  bool live = false,
  AdaptiveFormat? audio,
  AdaptiveFormat? video,
}) =>
    Video(
        videoId: id,
        liveNow: live,
        adaptiveFormats: [audio ?? _audio(), video ?? _video()]);

DownloadPlaybackProvenance? _provenance({
  Server server = _server,
  Video? content,
  bool audioOnly = true,
  DownloadContainer container = DownloadContainer.webm,
  AdaptiveFormat? audio,
  AdaptiveFormat? video,
  int byteLength = 10000,
  String? hash,
}) =>
    DownloadPlaybackProvenance.create(
        video: content ?? _content(audio: audio, video: video),
        server: server,
        audioOnly: audioOnly,
        container: container,
        audio: audio ?? _audio(),
        videoFormat: video ?? (audioOnly ? null : _video()),
        byteLength: byteLength,
        sha256: hash ?? _hash);

bool _matches(DownloadPlaybackProvenance provenance,
        {Server server = _server,
        Video? content,
        bool audioOnly = true,
        DownloadContainer container = DownloadContainer.webm,
        AdaptiveFormat? audio,
        AdaptiveFormat? video}) =>
    provenance.matchesSelection(
        video: content ?? _content(audio: audio, video: video),
        server: server,
        audioOnly: audioOnly,
        container: container,
        audio: audio ?? _audio(),
        videoFormat: video ?? (audioOnly ? null : _video()));

void main() {
  test('completed audio file round trips with an exact selection and digest',
      () {
    final provenance = _provenance()!;
    final restored = DownloadPlaybackProvenance.tryFromJson(
        jsonDecode(jsonEncode(provenance.toJson())))!;

    expect(restored.toJson(), provenance.toJson());
    expect(restored, provenance);
    expect(restored.hashCode, provenance.hashCode);
    expect(restored.audio, provenance.audio);
    expect(restored.audio.hashCode, provenance.audio.hashCode);
    expect(restored.profileId, 'person-a');
    expect(restored.accountId, 'account-a');
    expect(restored.origin, 'https://inv.example');
    expect(restored.contentId, 'song');
    expect(restored.audioOnly, isTrue);
    expect(restored.container, DownloadContainer.webm);
    expect(restored.videoFormat, isNull);
    expect(restored.videoHeight, isNull);
    expect(restored.defaultAudioTrack, isTrue);
    expect(_matches(restored), isTrue);
    expect(restored.matchesOutput(byteLength: 10000, sha256: _hash), isTrue);
    expect(restored.matchesOutput(byteLength: 9999, sha256: _hash), isFalse);
    expect(
        restored.matchesOutput(
            byteLength: 10000, sha256: List.filled(64, 'b').join()),
        isFalse);
    expect(DownloadPlaybackProvenance.optionalToJson(restored),
        provenance.toJson());
    expect(DownloadPlaybackProvenance.optionalToJson(null), isNull);
  });

  test('mux reuse requires both whole renditions and the original mode', () {
    final mux = _provenance(audioOnly: false)!;
    expect(mux.videoHeight, 1080);
    expect(_matches(mux, audioOnly: false), isTrue);
    expect(_matches(mux), isFalse);
    expect(_matches(_provenance()!, audioOnly: false), isFalse);
    expect(_matches(mux, audioOnly: false, audio: _audio(lmt: '1700000000001')),
        isFalse);
    expect(
        _matches(mux, audioOnly: false, video: _video(clen: '54322')), isFalse);
    expect(
        mux.matchesSelection(
            video: _content(),
            server: _server,
            audioOnly: false,
            container: DownloadContainer.webm,
            audio: _audio()),
        isFalse);
    expect(_provenance(video: _video()), isNull);
  });

  test('profile account origin and content each isolate saved media', () {
    final provenance = _provenance()!;
    expect(
        _matches(provenance, server: _server.copyWith(profileId: 'person-b')),
        isFalse);
    expect(_matches(provenance, server: _server.copyWith(id: 'account-b')),
        isFalse);
    for (final origin in [
      'https://other.example',
      'http://inv.example',
      'https://inv.example:8443',
    ]) {
      final audio = _audio(url: '$origin/videoplayback?itag=251');
      expect(
          _matches(provenance,
              server: _server.copyWith(url: origin), audio: audio),
          isFalse);
    }
    expect(_matches(provenance, content: _content(id: 'other')), isFalse);
    expect(_matches(provenance, container: DownloadContainer.mp4), isFalse);
  });

  test('metadata-free selection checks owner mode default track and quality',
      () {
    final audio = _provenance()!;
    final mux = _provenance(audioOnly: false)!;
    bool matches(DownloadPlaybackProvenance proof,
            {Server server = _server,
            String contentId = 'song',
            bool audioOnly = true,
            int? quality}) =>
        proof.matchesScope(
            server: server,
            contentId: contentId,
            audioOnly: audioOnly,
            preferredQuality: quality);
    expect(matches(audio), isTrue);
    expect(matches(mux, audioOnly: false), isTrue);
    expect(matches(mux, audioOnly: false, quality: 1080), isTrue);
    expect(matches(mux, audioOnly: false, quality: 720), isFalse);
    expect(matches(mux, audioOnly: false, quality: 2160), isFalse);
    expect(matches(mux), isFalse);
    expect(matches(audio, audioOnly: false), isFalse);
    expect(matches(audio, contentId: 'other'), isFalse);
    expect(
        matches(audio, server: _server.copyWith(profileId: 'other')), isFalse);
    expect(matches(audio, server: _server.copyWith(id: 'other')), isFalse);
    expect(
        matches(audio, server: _server.copyWith(url: 'https://other.example')),
        isFalse);
    expect(matches(_provenance(audio: _audio(defaultTrack: false))!), isFalse);
    expect(matches(_provenance(audio: _audio(track: null))!), isTrue);
    // A deliberately selected nondefault track can still match current exact
    // metadata. Only metadata-free automatic selection requires default status.
    expect(_matches(_provenance(audio: _audio(defaultTrack: false))!), isTrue);
  });

  test('signed URL refresh is compatible and agrees with cache identity', () {
    final provenance = _provenance()!;
    final refreshed = _audio(
        url: 'https://inv.example/videoplayback?itag=251&sig=new&expire=9999');
    expect(_matches(provenance, audio: refreshed), isTrue);
    expect(provenance.audio.matchesFormat(refreshed, _server), isTrue);
    final payload = playbackCacheIdentity(
        video: _content(audio: refreshed),
        server: _server,
        sourceUrl: refreshed.url,
        sessionId: 'test')!;
    final resource = (payload['resources'] as List<Map<String, Object?>>).first;
    final key = jsonDecode(resource['key'] as String) as List;
    expect(provenance.audio.itag, key[1]);
    expect(provenance.audio.clen, key[2]);
    expect(provenance.audio.lmt, key[3]);
    expect(provenance.audio.typeSha256, key[4]);
    expect(provenance.audio.audioTrackSha256, key[5]);
    expect(provenance.audio.trackDimensionsSha256, key[6]);
  });

  test('every immutable audio dimension invalidates reuse', () {
    final provenance = _provenance()!;
    for (final audio in [
      _audio(url: 'https://inv.example/videoplayback?itag=250', itag: '250'),
      _audio(clen: '12346'),
      _audio(lmt: '1700000000001'),
      _audio(type: 'audio/webm; codecs="vorbis"'),
      _audio(track: 'es.1'),
      _audio(track: null),
      _audio(url: 'https://inv.example/videoplayback?itag=251&lang=es'),
      _audio(url: 'https://inv.example/videoplayback?itag=251&xtags=lang:en'),
    ]) {
      expect(_matches(provenance, audio: audio), isFalse);
    }
  });

  test('audio identity cannot mask an incompatible mux video rendition', () {
    final provenance = _provenance(audioOnly: false)!;
    for (final video in [
      _video(url: 'https://inv.example/videoplayback?itag=247', itag: '247'),
      _video(clen: '54322'),
      _video(lmt: '1700000000001'),
      _video()..type = 'video/webm; codecs="vp09.00.51.08"',
    ]) {
      expect(_matches(provenance, audioOnly: false, video: video), isFalse);
    }
  });

  test('value equality covers every owner rendition and output dimension', () {
    final provenance = _provenance()!;
    for (final changed in [
      _provenance(server: _server.copyWith(profileId: 'person-b'))!,
      _provenance(server: _server.copyWith(id: 'account-b'))!,
      _provenance(content: _content(id: 'other'))!,
      _provenance(audio: _audio(clen: '12346'))!,
      _provenance(audio: _audio(defaultTrack: false))!,
      _provenance(byteLength: 10001)!,
      _provenance(hash: 'b' * 64)!,
      _provenance(audioOnly: false)!,
    ]) {
      expect(changed, isNot(provenance));
    }
    final uppercase = _provenance(hash: _hash.toUpperCase())!;
    expect(uppercase, provenance);
    expect(uppercase.sha256, _hash);
    expect(
        uppercase.matchesOutput(byteLength: 10000, sha256: _hash.toUpperCase()),
        isTrue);
  });

  test('mutable format objects cannot mutate saved identity', () {
    final audio = _audio();
    final provenance = _provenance(audio: audio)!;
    final before = jsonEncode(provenance.toJson());
    audio.clen = '2';
    audio.url = 'https://evil.example/media';
    audio.audioTrack = const AudioTrack(id: 'fr', displayName: 'French');
    expect(jsonEncode(provenance.toJson()), before);
    expect(_matches(provenance), isTrue);
  });

  test('incomplete conflicting partial and manifest sources are ineligible',
      () {
    for (final audio in [
      _audio(itag: ''),
      _audio(clen: '0'),
      _audio(clen: '-1'),
      _audio(lmt: ''),
      _audio(lmt: 'NaN'),
      _audio(type: ''),
      _audio(url: 'https://inv.example/videoplayback?itag=250'),
      _audio(url: 'https://inv.example/videoplayback?clen=12345&clen=12346'),
      _audio(url: 'https://inv.example/videoplayback?range=0-10'),
      _audio(url: 'https://inv.example/videoplayback?segment=1'),
      _audio(url: 'https://inv.example/videoplayback?lang=%FF'),
      _audio(url: 'https://inv.example/api/manifest/dash/id/song'),
      _audio(url: 'https://inv.example/media.m3u8'),
    ]) {
      expect(_provenance(audio: audio), isNull);
    }
  });

  test('unadmitted sources and official instance origins cannot persist', () {
    for (final url in [
      'https://evil.example/videoplayback',
      'https://user:secret@inv.example/videoplayback',
      'file:///tmp/media',
    ]) {
      expect(_provenance(audio: _audio(url: url)), isNull);
    }
    final direct = _audio(
        url: 'https://r1.googlevideo.com/videoplayback?itag=251&sig=secret');
    // The allowed source still has to be rewritten through the chosen instance.
    expect(_provenance(audio: direct), isNotNull);
    expect(
        _provenance(
            server: _server.copyWith(url: 'https://youtube.com'),
            audio: _audio(url: 'https://youtube.com/videoplayback')),
        isNull);
  });

  test('live metadata absent selections and incompatible containers reject',
      () {
    final provenance = _provenance()!;
    expect(_provenance(content: _content(live: true)), isNull);
    expect(_matches(provenance, content: _content(live: true)), isFalse);
    expect(_provenance(content: const Video(videoId: 'song')), isNull);
    expect(
        _matches(provenance, content: const Video(videoId: 'song')), isFalse);
    expect(_provenance(container: DownloadContainer.mp4), isNull);
    expect(_provenance(audio: _video()), isNull);
    expect(_provenance(audioOnly: false, video: _audio()), isNull);
    expect(_provenance(content: _content(audio: _audio(lmt: '1700000000001'))),
        isNull);
  });

  test('conflicting current metadata cannot authorize the same source URL', () {
    final current = Video(videoId: 'song', adaptiveFormats: [
      _audio(),
      _audio(lmt: '1700000000001'),
    ]);
    expect(_provenance(content: current), isNull);
    expect(_matches(_provenance()!, content: current), isFalse);
  });

  test('MP4 audio and mux output retain their container requirements', () {
    final audio = _audio(
        url: 'https://inv.example/videoplayback?itag=140',
        itag: '140',
        type: 'audio/mp4; codecs="mp4a.40.2"')
      ..encoding = 'aac'
      ..container = 'm4a';
    final video =
        _video(url: 'https://inv.example/videoplayback?itag=137', itag: '137')
          ..type = 'video/mp4; codecs="avc1.640028"'
          ..encoding = 'h264'
          ..container = 'mp4';
    final provenance = _provenance(
        container: DownloadContainer.mp4,
        audioOnly: false,
        audio: audio,
        video: video)!;
    expect(
        _matches(provenance,
            container: DownloadContainer.mp4,
            audioOnly: false,
            audio: audio,
            video: video),
        isTrue);
  });

  test('legacy malformed and future provenance is ignored safely', () {
    final valid = _provenance()!.toJson();
    final invalid = <Object?>[
      null,
      false,
      [],
      'not-json',
      <String, Object?>{},
      {'videoId': 'song', 'downloadComplete': true},
      {...valid, 'version': 0},
      {...valid, 'version': 2},
      {...valid, 'version': '1'},
      {...valid, 'version': 1.0},
      {...valid, 'profileId': ''},
      {...valid, 'accountId': ''},
      {...valid, 'accountId': 'https://inv.example?token=secret'},
      {...valid, 'accountId': 'https://user:secret@inv.example'},
      {...valid, 'contentId': ''},
      {...valid, 'origin': 'https://user:secret@inv.example'},
      {...valid, 'origin': 'https://inv.example/path?secret=token'},
      {...valid, 'origin': 'https://youtube.com'},
      {...valid, 'audioOnly': 1},
      {...valid, 'defaultAudioTrack': null},
      {...valid, 'defaultAudioTrack': 1},
      {...valid, 'videoHeight': 1080},
      {...valid, 'container': 'avi'},
      {...valid, 'byteLength': 0},
      {...valid, 'byteLength': -1},
      {...valid, 'byteLength': 10000.0},
      {...valid, 'sha256': 'a' * 63},
      {...valid, 'sha256': 'z' * 64},
      {...valid, 'sha256': ' $_hash'},
      {...valid, 'audio': null},
      {...valid, 'audio': {}},
      {...valid, 'audioOnly': false, 'videoFormat': null},
      {
        ...valid,
        'videoFormat': _provenance(audioOnly: false)!.videoFormat!.toJson()
      },
    ];
    for (final value in invalid) {
      expect(DownloadPlaybackProvenance.tryFromJson(value), isNull);
    }
    expect(_provenance(byteLength: 0), isNull);
    expect(_provenance(hash: 'invalid'), isNull);
    expect(_provenance(audioOnly: false, video: _video()..qualityLabel = null),
        isNull);
    final mux = _provenance(audioOnly: false)!.toJson();
    for (final height in [null, 0, -1, 1080.0, '1080']) {
      expect(
          DownloadPlaybackProvenance.tryFromJson(
              {...mux, 'videoHeight': height}),
          isNull);
    }
    expect(
        DownloadPlaybackProvenance.tryFromJson(
            {...valid}..remove('videoHeight')),
        isNull);
  });

  test('malformed nested rendition never becomes eligible', () {
    final provenance = _provenance()!;
    final valid = provenance.toJson();
    final audio = provenance.audio.toJson();
    final missingTrack = {...audio}..remove('audioTrackSha256');
    for (final rendition in [
      missingTrack,
      {...audio, 'itag': '0'},
      {...audio, 'itag': 251},
      {...audio, 'clen': '-1'},
      {...audio, 'lmt': '100000000000000000000'},
      {...audio, 'typeSha256': ''},
      {...audio, 'audioTrackSha256': 'raw-language'},
      {...audio, 'trackDimensionsSha256': 'bad'},
    ]) {
      expect(
          DownloadPlaybackProvenance.tryFromJson(
              {...valid, 'audio': rendition}),
          isNull);
    }
  });

  test('serialization retains no media URL signature or authorization material',
      () {
    final server = _server.copyWith(
        authToken: 'authorization-secret',
        sidCookie: 'cookie-secret',
        customHeaders: {'X-Api-Key': 'header-secret'});
    final audio = _audio(
        url: 'https://inv.example/videoplayback?itag=251&sig=signature-secret'
            '&lang=untrusted-query-secret',
        track: 'untrusted-track-secret');
    final serialized =
        jsonEncode(_provenance(server: server, audio: audio)!.toJson());
    for (final value in [
      'videoplayback',
      'signature-secret',
      'untrusted-query-secret',
      'untrusted-track-secret',
      'authorization-secret',
      'cookie-secret',
      'header-secret',
    ]) {
      expect(serialized, isNot(contains(value)));
    }
  });
}
