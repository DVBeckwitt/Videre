import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/download_audio_tracks.dart';
import 'package:clipious/videos/states/download_modal_sheet.dart';
import 'package:clipious/videos/views/components/download_modal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Metadata extends Service {
  _Metadata({int status = 403, Map<String, String> headers = const {}})
      : super(
            httpClient: MockClient((request) async => http.Response(
                'Unavailable', status,
                headers: headers, request: request)));

  @override
  Future<Video> getDownloadVideo(String videoId,
          {required BackendPlayback route,
          required void Function() checkCurrent}) async =>
      Video(
        videoId: videoId,
        dashUrl: 'https://inv.example/api/manifest/dash/id/$videoId',
        adaptiveFormats: [
          AdaptiveFormat(null, '128000', null, 'https://inv.example/audio',
              '251', 'audio/webm', '100', '1', '', 'webm', 'opus', null, null),
          AdaptiveFormat(
              null,
              '256000',
              null,
              'https://inv.example/video',
              '247',
              'video/webm',
              '100',
              '1',
              '',
              'webm',
              'vp9',
              '720p',
              '720p'),
        ],
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Service previous;
  setUp(() async {
    previous = service;
    db = await SembastSqfDb.createInMemory();
    await db.useServer(const Server(id: 'account', url: 'https://inv.example'));
    service = _Metadata();
  });
  tearDown(() async {
    service = previous;
    await db.close();
  });

  test('optional DASH refusal retains the original audio and video choices',
      () async {
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);
    if (cubit.state.loading) {
      await cubit.stream.firstWhere((state) => !state.loading);
    }
    expect(cubit.state.audioTrackDiscoveryFailed, isTrue);
    expect(cubit.state.failed, isFalse);
    expect(cubit.state.availableQualities.single.qualityLabel, '720p');
    expect(cubit.canSelectVideo, isTrue);
    cubit.setAudioOnly(true);
    expect(cubit.state.audioOnly, isTrue);
    expect(cubit.state.failed, isFalse);
  });

  test('an instance cooldown during optional DASH prevents queuing media',
      () async {
    service = _Metadata(status: 429, headers: {'retry-after': '600'});
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);
    if (cubit.state.loading) {
      await cubit.stream.firstWhere((state) => !state.loading);
    }
    expect(cubit.state.failed, isTrue);
    expect(await cubit.canStartDownload(), isFalse);
  });

  test('revoked discovery stops before requesting a signed manifest', () async {
    final firstRequest = Completer<void>();
    final firstResponse = Completer<void>();
    final requests = <Uri>[];
    var current = true;
    final client = MockClient((request) async {
      requests.add(request.url);
      if (!firstRequest.isCompleted) firstRequest.complete();
      await firstResponse.future;
      return http.Response('No check ID.', 400, request: request);
    });
    final result = loadDownloadAudioTracks(
        const Video(
            videoId: 'video',
            dashUrl: 'https://inv.example/api/manifest/dash/id/video'),
        await db.getCurrentlySelectedServer(),
        client: client, checkCurrent: () {
      if (!current) throw StateError('Picker closed');
    });
    await firstRequest.future;
    current = false;
    firstResponse.complete();
    await expectLater(result, throwsStateError);
    expect(requests, hasLength(1));
  });

  testWidgets('optional DASH refusal shows a warning with an enabled download',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: const Scaffold(
          body: DownloadModalSheet(video: Video(videoId: 'video'))),
    ));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(DownloadModalSheet));
    expect(
        find.text(
            AppLocalizations.of(context)!.downloadAudioLanguagesUnavailable),
        findsOneWidget);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });
}
