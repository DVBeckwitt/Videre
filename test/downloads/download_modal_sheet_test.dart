import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/services/ytdlnis_download.dart';
import 'package:clipious/downloads/views/components/ytdlnis_download_action.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/download_modal_sheet.dart';
import 'package:clipious/videos/views/components/download_modal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Metadata extends Service {
  final Future<Video> Function() fetch;
  final started = Completer<void>();
  final accounts = <Server?>[];

  _Metadata(this.fetch);

  @override
  Future<Video> getDownloadVideo(String videoId,
      {required BackendPlayback route, required void Function() checkCurrent}) {
    checkCurrent();
    accounts.add(route.server);
    if (!started.isCompleted) started.complete();
    return fetch();
  }
}

AdaptiveFormat _format(
        {String type = 'audio/webm',
        String encoding = 'vp9',
        String? quality,
        String? resolution,
        String url = 'https://instance.invalid/stream',
        String size = '100'}) =>
    AdaptiveFormat(null, '128000', null, url, '251', type, size, '1', '', null,
        encoding, quality, resolution);

Video _playable() => Video(videoId: 'video', adaptiveFormats: [
      _format(),
      _format(type: 'video/webm', quality: '720p', resolution: '720p'),
    ]);

Future<void> _loaded(DownloadModalSheetCubit cubit) async {
  if (cubit.state.loading) {
    await cubit.stream
        .firstWhere((state) => !state.loading)
        .timeout(const Duration(seconds: 2));
  }
}

Future<void> _showSheet(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: const Scaffold(
        body: DownloadModalSheet(video: Video(videoId: 'video'))),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const account = Server(
      id: 'original', url: 'https://instance.invalid', authToken: 'original');
  late Service originalService;

  setUp(() async {
    originalService = service;
    db = await SembastSqfDb.createInMemory();
    await db.useServer(account);
  });

  tearDown(() async {
    service = originalService;
    await db.close();
  });

  final selector = BackendSelector('backend',
      const [BackendOption('a', 'First'), BackendOption('b', 'Second')]);

  for (final (audioOnly, direct) in [
    (false, false),
    (false, true),
    (true, false)
  ]) {
    testWidgets(
        'YTDLnis requires a tap and shares only the ID ($audioOnly, $direct)',
        (tester) async {
      final metadata = _Metadata(() async => _playable());
      service = metadata;
      final requests = <MethodCall>[];
      final result = Completer<String>();
      const channel = MethodChannel('videre/ytdlnis_download');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        requests.add(call);
        return result.future;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      const item = Video(videoId: 'tV5UilNUYRY', isListed: true);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
                onPressed: () {
                  if (audioOnly) {
                    unawaited(DownloadModalSheet.showPlaylistOptions(context,
                        musicAudioOnly: true, externalVideo: item));
                  } else if (direct) {
                    unawaited(showModalBottomSheet<void>(
                        context: context,
                        builder: (_) => const YtdlnisDownloadAction(
                            video: item, audioOnly: false)));
                  } else {
                    DownloadModalSheet.showVideoModalSheet(context, item);
                  }
                },
                child: const Text('Open')),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final externalAction = find.text('Download with YTDLnis');
      expect(externalAction, findsOneWidget);
      expect(requests, isEmpty);
      final builtInRequests = audioOnly || direct ? 0 : 1;
      expect(metadata.accounts, hasLength(builtInRequests));

      await tester.ensureVisible(externalAction);
      await tester.tap(externalAction);
      await tester.pump();
      expect(find.text('Opening YTDLnis…'), findsOneWidget);
      final button = find.ancestor(
          of: externalAction,
          matching:
              find.byWidgetPredicate((widget) => widget is OutlinedButton));
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.ensureVisible(externalAction);
      await tester.tap(externalAction);
      expect(requests, hasLength(1));
      result.complete(audioOnly || direct ? 'opened' : 'unavailable');
      await tester.pumpAndSettle();
      expect(find.text('Opening YTDLnis…'), findsNothing);
      expect(requests.single.method, 'open');
      expect(requests.single.arguments,
          {'videoId': 'tV5UilNUYRY', 'audioOnly': audioOnly});
      expect(metadata.accounts, hasLength(builtInRequests));
      if (audioOnly || direct) {
        expect(externalAction, findsNothing);
      } else {
        expect(find.text('Install or update YTDLnis to open this download.'),
            findsOneWidget);
        expect(find.byTooltip('Download'), findsOneWidget);
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('YTDLnis refuses local, unlisted and malformed video inputs',
      (tester) async {
    var requests = 0;
    const channel = MethodChannel('videre/ytdlnis_download');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      requests++;
      return 'opened';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    for (final item in [
      const Video(videoId: 'device:track'),
      const Video(videoId: 'tV5UilNUYRY', isListed: false),
      const Video(videoId: 'tV5UilNUYRY', downloadPlaybackOnly: true),
      const Video(videoId: 'tV5UilNUYRY', explicitMusicDownload: 'download'),
      const Video(videoId: 'tV5UilNUYRY', premium: true),
      const Video(videoId: 'https://private.invalid/watch?v=tV5UilNUYRY'),
      const Video(videoId: 'tV5UilNUYRY&list=playlist'),
    ]) {
      expect(await YtdlnisDownload.open(item, audioOnly: true),
          YtdlnisOpenResult.unavailable);
    }
    expect(requests, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final hasFormats in [true, false]) {
    testWidgets(
        'Watch withdraws YTDLnis after metadata identifies an unlisted video '
        '(formats available: $hasFormats)', (tester) async {
      const id = 'tV5UilNUYRY';
      final response = Completer<Video>();
      final metadata = _Metadata(() => response.future);
      service = metadata;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home:
            const Scaffold(body: DownloadModalSheet(video: Video(videoId: id))),
      ));
      await tester.pump();
      expect(find.text('Download with YTDLnis'), findsOneWidget);

      response.complete(Video(
          videoId: id,
          isListed: false,
          adaptiveFormats: hasFormats ? _playable().adaptiveFormats : []));
      await tester.pumpAndSettle();
      expect(find.text('Download with YTDLnis'), findsNothing);
      expect(hasFormats ? find.byTooltip('Download') : find.text('Retry'),
          findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  for (final failure in ['unavailable', 'missing audio', 'foreign media']) {
    test('picker recovers on another backend after $failure', () async {
      final preferred = selector.withSelection(
          account.copyWith(backendSelector: selector), 'a');
      await db.upsertServer(preferred);
      var attempts = 0;
      final metadata = _Metadata(() async {
        if (++attempts == 1) {
          if (failure == 'missing audio') return const Video(videoId: 'video');
          if (failure == 'foreign media') {
            return Video(videoId: 'video', adaptiveFormats: [
              _format(url: 'https://other.invalid/stream')
            ]);
          }
          throw InvidiousServiceError('Unavailable', statusCode: 503);
        }
        return _playable();
      });
      service = metadata;
      final cubit = DownloadModalSheetCubit(
          const DownloadModalSheetState(), const Video(videoId: 'video'));
      addTearDown(cubit.close);

      await _loaded(cubit);
      expect(cubit.state.failed, isFalse);
      expect(cubit.state.availableQualities.single.qualityLabel, '720p');
      expect(metadata.accounts.map((route) => selector.selectedValue(route!)),
          ['a', 'b']);
      expect(metadata.accounts.map((route) => route?.accountId),
          everyElement(account.accountId));
      expect(
          selector.selectedValue(await db.getCurrentlySelectedServer()), 'a');
    });
  }

  test('a rate-limited picker leaves all alternate backends untouched',
      () async {
    final preferred = selector.withSelection(
        account.copyWith(backendSelector: selector), 'a');
    await db.upsertServer(preferred);
    final metadata = _Metadata(() async {
      throw InvidiousServiceError('Rate limited',
          statusCode: 429, retryAfter: const Duration(hours: 1));
    });
    service = metadata;
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);

    await _loaded(cubit);
    expect(cubit.state.failed, isTrue);
    expect(selector.selectedValue(metadata.accounts.single!), 'a');
  });

  for (final (status, code) in [(429, 'rate_limited'), (503, 'unavailable')]) {
    test(
        'reopened NerdVPN picker retries a 429 and respects a 503 outage ($code)',
        () async {
      final preferred = selector.withSelection(
          account.copyWith(
              url: 'https://invidious.nerdvpn.de', backendSelector: selector),
          'a');
      await db.upsertServer(preferred);
      await db.useServer(preferred);
      final limited = _Metadata(() async {
        throw InvidiousServiceError('Gateway temporarily unavailable',
            statusCode: status,
            errorCode: code,
            isGatewayResponse: true,
            retryAfter: const Duration(minutes: 2));
      });
      service = limited;
      final first = DownloadModalSheetCubit(
          const DownloadModalSheetState(), const Video(videoId: 'video'));
      addTearDown(first.close);
      await _loaded(first);
      expect(limited.accounts.single!.url, preferred.url);
      final deadline = first.state.retryAt;
      expect(deadline, status == 429 ? isNull : isNotNull);

      final restarted =
          _Metadata(() async => Video(videoId: 'other', adaptiveFormats: [
                _format(url: '${preferred.url}/stream'),
                _format(
                    type: 'video/webm',
                    quality: '720p',
                    resolution: '720p',
                    url: '${preferred.url}/stream'),
              ]));
      service = restarted;
      final second = DownloadModalSheetCubit(
          const DownloadModalSheetState(), const Video(videoId: 'other'));
      addTearDown(second.close);
      await _loaded(second);
      expect(restarted.accounts, hasLength(status == 429 ? 1 : 0));
      expect(second.state.retryAt, deadline);
      expect(second.state.failed, status == 503);
    });
  }

  test('saved picker choices expire when the same account changes credentials',
      () async {
    service = _Metadata(() async => _playable());
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);
    await _loaded(cubit);
    expect(await cubit.canStartDownload(), isTrue);

    await db.upsertServer(account.copyWith(authToken: 'changed'));
    expect(await cubit.canStartDownload(), isFalse);
  });

  for (final formats in <List<AdaptiveFormat>?>[
    null,
    [],
    [_format(type: 'video/mp4', quality: '720p')],
    [_format(type: 'video/webm', quality: '720p')],
  ]) {
    test('missing compatible audio finishes with a retryable error: $formats',
        () async {
      service = _Metadata(
          () async => Video(videoId: 'video', adaptiveFormats: formats));
      final cubit = DownloadModalSheetCubit(
          const DownloadModalSheetState(), const Video(videoId: 'video'));
      addTearDown(cubit.close);

      await _loaded(cubit);

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.failed, isTrue);
    });
  }

  testWidgets('a long picker cooldown shows the deadline and waits for Retry',
      (tester) async {
    final metadata = _Metadata(() async {
      throw InvidiousServiceError('Rate limited',
          statusCode: 429, retryAfter: const Duration(minutes: 2));
    });
    service = metadata;
    await _showSheet(tester);
    FilledButton retry() => tester.widget<FilledButton>(
        find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(find.textContaining('Try again after'), findsOneWidget);
    expect(retry().onPressed, isNull);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    expect(retry().onPressed, isNotNull);
    expect(metadata.accounts, hasLength(1));
  });

  testWidgets('canceling during a short picker cooldown stops automatic retry',
      (tester) async {
    final metadata = _Metadata(() async {
      throw InvidiousServiceError('Rate limited',
          statusCode: 429, retryAfter: const Duration(seconds: 8));
    });
    service = metadata;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => DownloadModalSheet.showVideoModalSheet(
                      context, const Video(videoId: 'video')),
                  child: const Text('Open')))),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting to retry automatically…'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 9));
    expect(metadata.accounts, hasLength(1));
    expect(find.text('Open'), findsOneWidget);
    expect(find.byType(DownloadModalSheet), findsNothing);
  });

  testWidgets('metadata failure shows Retry and a retry restores choices',
      (tester) async {
    var attempts = 0;
    final metadata = _Metadata(() async {
      if (++attempts == 1) {
        throw InvidiousServiceError('Metadata unavailable', statusCode: 404);
      }
      return _playable();
    });
    service = metadata;
    await _showSheet(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.download), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(metadata.accounts.map((server) => server?.accountId),
        [account.accountId, account.accountId]);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.byIcon(Icons.download), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty formats show an error instead of an endless spinner',
      (tester) async {
    service = _Metadata(() async => const Video(videoId: 'video'));
    await _showSheet(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.download), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio-only metadata retains the existing audio download option',
      (tester) async {
    service = _Metadata(
        () async => Video(videoId: 'video', adaptiveFormats: [_format()]));
    await _showSheet(tester);

    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNull);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('duplicate qualities and malformed size metadata remain usable',
      (tester) async {
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          _format(),
          _format(
              type: 'video/webm',
              quality: '720p',
              resolution: 'unknown',
              size: 'NaN'),
          _format(type: 'video/webm', quality: '720p'),
        ]));
    await _showSheet(tester);

    final dropdown = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    expect(dropdown.items, hasLength(1));
    expect(dropdown.value, '720p');
    expect(tester.takeException(), isNull);
  });

  testWidgets('size estimates include the selected audio and container',
      (tester) async {
    AdaptiveFormat audio(
            String container, String size, String language) =>
        _format(
            type: 'audio/$container',
            encoding: container == 'mp4' ? 'aac' : 'opus',
            size: size)
          ..audioTrack = AudioTrack(
              id: language,
              displayName: language,
              audioIsDefault: language == 'en');
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          audio('mp4', '8860752', 'en'),
          audio('mp4', '1000000', 'fr'),
          audio('webm', '100000', 'en'),
          audio('webm', '3000000', 'fr'),
          _format(
              type: 'video/mp4',
              encoding: 'h264',
              quality: '240p',
              size: '1410703'),
          _format(type: 'video/webm', quality: '240p', size: '2200000'),
        ]));
    await _showSheet(tester);

    void container(DownloadContainer value) => tester
        .widget<DropdownButton<int>>(find.byType(DropdownButton<int>))
        .onChanged!(value.index);
    void language(String value) => tester
        .widgetList<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .firstWhere((menu) => menu.items!.any((item) => item.value == 'fr'))
        .onChanged!(value);
    String qualityLabel() => (tester
            .widgetList<DropdownButton<String>>(
                find.byType(DropdownButton<String>))
            .firstWhere(
                (menu) => menu.items!.any((item) => item.value == '240p'))
            .items!
            .single
            .child as Text)
        .data!;

    container(DownloadContainer.mp4);
    await tester.pumpAndSettle();
    expect(qualityLabel(), '240p (~10.3 MB)');
    language('fr');
    await tester.pumpAndSettle();
    expect(qualityLabel(), '240p (~2.41 MB)');
    container(DownloadContainer.webm);
    await tester.pumpAndSettle();
    expect(qualityLabel(), '240p (~5.2 MB)');
    language('en');
    await tester.pumpAndSettle();
    expect(qualityLabel(), '240p (~2.3 MB)');
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown audio size does not show the video size as the total',
      (tester) async {
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          _format(size: 'unknown'),
          _format(type: 'video/webm', quality: '720p', size: '2000000'),
        ]));
    await _showSheet(tester);

    final menu = tester
        .widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    expect((menu.items!.single.child as Text).data, '720p');
    expect(tester.takeException(), isNull);
  });

  test('HD MP4 is offered alongside a low-resolution WebM track', () async {
    final webm = _format(type: 'video/webm', quality: '360p');
    final hd = _format(type: 'video/mp4', encoding: 'h264', quality: '1080p');
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          _format(type: 'audio/mp4', encoding: 'aac'),
          _format(type: 'video/mp4', encoding: 'h264', quality: '360p'),
          hd,
          _format(),
          webm,
        ]));
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);

    await _loaded(cubit);

    expect(cubit.state.availableQualities, [webm, hd]);
    expect(cubit.state.quality, '1080p');
    expect(cubit.state.audioOnly, isFalse);
  });

  test('M4A audio selection can return to available WebM video', () async {
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          _format(),
          _format(type: 'audio/mp4', encoding: 'aac'),
          _format(type: 'video/webm', quality: '720p'),
        ]));
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);
    await _loaded(cubit);
    cubit.setAudioOnly(true);
    cubit.setContainer(DownloadContainer.mp4);
    expect(cubit.state.container, DownloadContainer.mp4);
    expect(cubit.canSelectVideo, isTrue);
    cubit.setAudioOnly(false);
    expect(cubit.state.audioOnly, isFalse);
    expect(cubit.state.container, isNull);
    expect(cubit.state.availableQualities.single.qualityLabel, '720p');
  });

  test('audio-only language automatically clears video and subtitle choice',
      () async {
    final english = _format()
      ..audioTrack = const AudioTrack(
          id: 'en', displayName: 'English', audioIsDefault: true);
    final french = _format(type: 'audio/mp4', encoding: 'aac')
      ..audioTrack = const AudioTrack(id: 'fr', displayName: 'French');
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          english,
          french,
          _format(type: 'video/webm', quality: '720p'),
        ], captions: [
          Caption('English', 'en', '/api/v1/captions/video')
        ]));
    final cubit = DownloadModalSheetCubit(
        const DownloadModalSheetState(), const Video(videoId: 'video'));
    addTearDown(cubit.close);
    await _loaded(cubit);
    cubit.setCaption('English');
    expect(cubit.state.captionLabel, 'English');
    cubit.setAudioTrack('fr');
    expect(cubit.state.audioOnly, isTrue);
    expect(cubit.state.failed, isFalse);
    expect(cubit.state.captionLabel, isNull);
    expect(cubit.state.availableContainers, [DownloadContainer.mp4]);
    expect(cubit.canSelectVideo, isFalse);
    cubit.setAudioTrack('en');
    cubit.setAudioOnly(false);
    expect(cubit.state.availableQualities.single.qualityLabel, '720p');
    expect(cubit.state.audioOnly, isFalse);
  });

  testWidgets(
      'download choices scroll on a small screen with long track labels',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 480);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final audio = _format()
      ..audioTrack = const AudioTrack(
          id: 'en',
          displayName: 'English descriptive audio with an extended label');
    service = _Metadata(() async => Video(videoId: 'video', adaptiveFormats: [
          audio,
          _format(type: 'video/webm', quality: '720p'),
        ], captions: [
          Caption('English subtitles with an extended label', 'en', '/captions')
        ]));
    await _showSheet(tester);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byIcon(Icons.download));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'playlist options are discarded after the selected account changes',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (value) {
        context = value;
        return const SizedBox.shrink();
      })),
    ));
    final choosing = DownloadModalSheet.showPlaylistOptions(context);
    await tester.pumpAndSettle();
    await tester.runAsync(() => db.useServer(account.copyWith(id: 'changed')));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => choosing), isNull);
  });

  for (final switchPerson in [false, true]) {
    test(
        'late metadata does not enter a changed account or person '
        '(person: $switchPerson)', () async {
      final result = Completer<Video>();
      final metadata = _Metadata(() => result.future);
      service = metadata;
      final cubit = DownloadModalSheetCubit(
          const DownloadModalSheetState(), const Video(videoId: 'video'));
      addTearDown(cubit.close);
      await metadata.started.future;
      if (switchPerson) {
        final person = await db.createProfile('Other');
        await db.useProfile(person.id);
      }
      await db.useServer(account.copyWith(
          id: 'other', profileId: db.profileId, authToken: 'other'));
      result.complete(_playable());
      await Future<void>.delayed(Duration.zero);

      expect(metadata.accounts.single?.accountId, account.accountId);
      expect(metadata.accounts.single?.profileId, 'default');
      expect(cubit.state.availableQualities, isEmpty);
    });
  }

  for (final fail in [false, true]) {
    test('closing before metadata completes ignores late completion ($fail)',
        () async {
      final result = Completer<Video>();
      final metadata = _Metadata(() => result.future);
      service = metadata;
      final cubit = DownloadModalSheetCubit(
          const DownloadModalSheetState(), const Video(videoId: 'video'));
      await metadata.started.future;
      await cubit.close();
      if (fail) {
        result.completeError(const SocketException('Late failure'));
      } else {
        result.complete(_playable());
      }
      await Future<void>.delayed(Duration.zero);
      expect(cubit.isClosed, isTrue);
    });
  }
}
