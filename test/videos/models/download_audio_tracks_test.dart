import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/download_audio_tracks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const server = Server(
    url: 'https://inv.example', customHeaders: {'X-Test-Account': 'fixture'});
const manifestUrl = 'https://inv.example/api/manifest/dash/id/video';

String manifest({String suffix = '', String mediaHost = ''}) => '''
<MPD type="static"><Period>
  <AdaptationSet id="0" mimeType="audio/mp4" lang="en" label="English [128000k]">
    <Role value="main"/>
    <Representation id="140" codecs="mp4a.40.2" bandwidth="128000">
      <AudioChannelConfiguration value="2"/>
      <BaseURL>$mediaHost/videoplayback?itag=140&amp;lang=en&amp;check=$suffix</BaseURL>
      <SegmentBase indexRange="100-200"><Initialization range="0-99"/></SegmentBase>
    </Representation>
  </AdaptationSet>
  <AdaptationSet id="1" mimeType="audio/mp4" lang="es" label="Español [128000k]">
    <Role value="alternate"/>
    <Representation id="140" codecs="mp4a.40.2" bandwidth="128000">
      <AudioChannelConfiguration value="2"/>
      <BaseURL>$mediaHost/videoplayback?itag=140&amp;lang=es&amp;check=$suffix</BaseURL>
      <SegmentBase indexRange="100-200"><Initialization range="0-99"/></SegmentBase>
    </Representation>
  </AdaptationSet>
</Period></MPD>
''';

void main() {
  test('DASH languages sharing an itag keep independent stable identities', () {
    final first =
        downloadAudioTracksFromManifest(manifest(), manifestUrl, server);
    final fresh = downloadAudioTracksFromManifest(
        manifest(suffix: 'fresh').replaceAll('id="1"', 'id="54"'),
        manifestUrl,
        server);
    expect(first, hasLength(2));
    expect(first.map((track) => track.itag), ['140', '140']);
    expect(first.map((track) => track.audioTrack!.displayName),
        ['English', 'Español']);
    expect(first.first.audioTrack!.audioIsDefault, isTrue);
    expect(first.last.audioTrack!.audioIsDefault, isFalse);
    expect(first.first.audioTrack!.id, isNot(first.last.audioTrack!.id));
    expect(fresh.map((track) => track.audioTrack!.id),
        first.map((track) => track.audioTrack!.id));
    expect(fresh.last.url, contains('check=fresh'));
    expect(first.last.encoding, 'aac');
    expect(first.last.clen, isEmpty);
  });

  test('manifest media must use the selected instance', () {
    expect(
        downloadAudioTracksFromManifest(
            manifest(mediaHost: 'https://other.example'), manifestUrl, server),
        isEmpty);
    final proxied = downloadAudioTracksFromManifest(
        manifest(mediaHost: 'https://rr1.googlevideo.com'),
        manifestUrl,
        server);
    expect(proxied, hasLength(2));
    expect(Uri.parse(proxied.first.url).origin, server.url);
    expect(Uri.parse(proxied.first.url).queryParameters['host'],
        'rr1.googlevideo.com');
  });

  test('live, multi-period and segmented representations are excluded', () {
    for (final body in [
      manifest().replaceAll('type="static"', 'type="dynamic"'),
      manifest().replaceAll('</MPD>', '<Period/></MPD>'),
      manifest()
          .replaceAll('<SegmentBase ', '<SegmentTemplate ')
          .replaceAll('</SegmentBase>', '</SegmentTemplate>'),
    ]) {
      expect(
          downloadAudioTracksFromManifest(body, manifestUrl, server), isEmpty);
    }
  });

  test('malformed XML and media URLs cannot remove existing download choices',
      () {
    expect(
        downloadAudioTracksFromManifest('<MPD>', manifestUrl, server), isEmpty);
    expect(
        downloadAudioTracksFromManifest(
            manifest(mediaHost: 'http://['), manifestUrl, server),
        isEmpty);
  });

  test('signed DASH URLs are fetched to discover tracks using account headers',
      () async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(manifest(), 200,
          request: request,
          headers: {'content-type': 'application/dash+xml; charset=utf-8'});
    });
    final video = await loadDownloadAudioTracks(
        const Video(videoId: 'video', dashUrl: '$manifestUrl?check=fixture'),
        server,
        client: client);
    expect(video.adaptiveFormats, hasLength(2));
    expect(requests, hasLength(1));
    expect(requests.single.url.queryParameters['local'], 'true');
    expect(requests.single.headers['X-Test-Account'], 'fixture');
  });

  test('DASH access refusal cannot be ignored as missing alternate tracks',
      () async {
    final client = MockClient(
        (request) async => http.Response('Forbidden', 403, request: request));
    await expectLater(
        loadDownloadAudioTracks(
            const Video(videoId: 'video', dashUrl: manifestUrl), server,
            client: client),
        throwsA(isA<InvidiousServiceError>()));
  });

  test('missing or unsafe manifests preserve existing metadata without a fetch',
      () async {
    final client =
        MockClient((_) async => throw StateError('Unexpected fetch'));
    for (final video in [
      const Video(videoId: 'video'),
      const Video(videoId: 'video', dashUrl: 'https://other.example/manifest'),
      const Video(videoId: 'video', dashUrl: manifestUrl, liveNow: true),
    ]) {
      expect(await loadDownloadAudioTracks(video, server, client: client),
          same(video));
    }
  });
}
