import 'dart:async';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/download_modal_sheet.dart';
import 'package:clipious/videos/views/components/download_modal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Metadata extends Service {
  final Future<Video> Function() fetch;
  final started = Completer<void>();
  final accounts = <Server?>[];

  _Metadata(this.fetch);

  @override
  Future<Video> getVideo(String videoId,
      {Server? serverOverride,
      void Function(BackendPlayback request)? onBackendRequest}) {
    accounts.add(serverOverride);
    if (!started.isCompleted) started.complete();
    return fetch();
  }
}

AdaptiveFormat _format(
        {String type = 'audio/webm',
        String encoding = 'vp9',
        String? quality,
        String? resolution,
        String size = '100'}) =>
    AdaptiveFormat(null, '128000', null, 'https://media.invalid/stream', '251',
        type, size, '1', '', null, encoding, quality, resolution);

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

  testWidgets('metadata failure shows Retry and a retry restores choices',
      (tester) async {
    var attempts = 0;
    final metadata = _Metadata(() async {
      if (++attempts == 1) throw const SocketException('Metadata unavailable');
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
