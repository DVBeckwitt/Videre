import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/models/sharelink.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _ShareDb implements IDbClient {
  _ShareDb(this.selected);

  Server selected;
  Completer<Server>? lookup;

  @override
  String profileId = 'default';

  @override
  IDbClient forProfile(String id) => this;

  @override
  Future<Server> getCurrentlySelectedServer() =>
      lookup?.future ?? Future.value(selected);

  @override
  Server? getAccount(String accountId) =>
      selected.accountId == accountId ? selected : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ShareApp extends AppCubit {
  _ShareApp(Server server) : super(AppState(0, server, HomeLayout())) {
    intentDataStreamSubscription = const Stream<void>.empty().listen((_) {});
  }

  @override
  void onReady() {}

  @override
  void initState() {}
}

class _SharePlayer implements PlayerCubit {
  @override
  Stream<PlayerState> get stream => const Stream.empty();

  @override
  final PlayerState state = PlayerState.init(null)
      .copyWith(position: const Duration(minutes: 1, seconds: 23));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  const video = Video(videoId: 'dQw4w9WgXcQ');
  final channel = Channel('Channel', 'UC_kRDKYrUlrbtrSiyu5Tflg', '', null, [],
      0, null, null, false, null, '', null, null);
  const server = Server(
      url: 'https://selected.example:8443/invidious/',
      inUse: true,
      authToken: 'private-token',
      sidCookie: 'private-cookie',
      customHeaders: {'Authorization': 'private-header'});

  test('video and music links retain selected instance and timestamp', () {
    final song = const MusicTrack(
        videoId: 'dQw4w9WgXcQ', title: 'Song', artists: ['Artist']).toVideo();
    for (final item in [video, song]) {
      expect(item.getInvidiousLink(server, 83).toString(),
          'https://selected.example:8443/invidious/watch?v=dQw4w9WgXcQ&t=83');
      expect(item.getInvidiousLink(server, null).queryParameters,
          {'v': 'dQw4w9WgXcQ'});
    }
  });

  test('channel links retain selected instance and omit video timestamps', () {
    expect(channel.getInvidiousLink(server, 83).toString(),
        'https://selected.example:8443/invidious/channel/UC_kRDKYrUlrbtrSiyu5Tflg');
  });

  test('links never carry credentials or request query data', () {
    final private = server.copyWith(
        url:
            'https://user:password@selected.example/base?token=secret#private');
    final link = video.getInvidiousLink(private, 0);
    expect(link.toString(),
        'https://selected.example/base/watch?v=dQw4w9WgXcQ&t=0');
  });

  test('metadata cannot inject a destination or extra query parameters', () {
    const untrusted = Video(videoId: 'id&next=https://youtube.com/watch');
    final link = untrusted.getInvidiousLink(server, null);
    expect(link.origin, 'https://selected.example:8443');
    expect(link.queryParameters, {'v': untrusted.videoId});
    final untrustedChannel = Channel.fromJson({
      ...channel.toJson(),
      'authorId': '../redirect?url=https://youtube.com',
    });
    expect(untrustedChannel.getInvidiousLink(server, null).pathSegments.last,
        untrustedChannel.authorId);
  });

  test('official YouTube and invalid server addresses cannot be shared', () {
    for (final address in [
      'https://youtube.com',
      'https://music.youtube.com',
      'https://youtu.be',
      'https://youtube.com.',
      'https://i.ytimg.com',
      'file:///tmp/instance',
      'not-a-server',
    ]) {
      expect(() => video.getInvidiousLink(Server(url: address), null),
          throwsFormatException);
    }
  });

  group('sharing sheet', () {
    const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
    late _ShareDb database;
    late _ShareApp app;
    late List<Map<Object?, Object?>> shared;
    late List<MethodCall> launched;
    Completer<String>? shareResult;

    setUp(() {
      database = _ShareDb(server);
      db = database;
      app = _ShareApp(server);
      shared = [];
      launched = [];
      shareResult = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(shareChannel, (call) async {
        shared.add(Map<Object?, Object?>.from(call.arguments as Map));
        return shareResult?.future ??
            'dev.fluttercommunity.plus/share/unavailable';
      });
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'), (call) async {
        launched.add(call);
        return true;
      });
    });

    tearDown(() async {
      await app.close();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(shareChannel, null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'), null);
    });

    Future<AppLocalizations> open(WidgetTester tester,
        {ShareLinks item = video, bool timestamp = false}) async {
      await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<AppCubit>.value(value: app),
          BlocProvider<PlayerCubit>.value(value: _SharePlayer()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Builder(builder: (context) {
            return TextButton(
                onPressed: () => showSharingSheet(context, item,
                    showTimestampOption: timestamp),
                child: const Text('Open sharing'));
          })),
        ),
      ));
      await tester.tap(find.text('Open sharing'));
      await tester.pumpAndSettle();
      return AppLocalizations.of(tester.element(find.byType(BottomSheet)))!;
    }

    testWidgets('only offers selected Invidious instance sharing',
        (tester) async {
      final locals = await open(tester);
      expect(find.text(locals.shareYoutubeLink), findsNothing);
      expect(find.text(locals.redirectInvidiousLink), findsNothing);
      expect(find.text(locals.shareInvidiousLink), findsOneWidget);
      await tester.tap(find.text(locals.shareInvidiousLink));
      await tester.pumpAndSettle();
      expect(shared.single, {
        'text': 'https://selected.example:8443/invidious/watch?v=dQw4w9WgXcQ'
      });
      expect(launched, isEmpty);
    });

    testWidgets('timestamp share retains the current playback position',
        (tester) async {
      final locals = await open(tester, timestamp: true);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text(locals.shareInvidiousLink));
      await tester.pumpAndSettle();
      expect(shared.single['text'],
          'https://selected.example:8443/invidious/watch?v=dQw4w9WgXcQ&t=83');
    });

    testWidgets('onion instance is shared as text without launching a browser',
        (tester) async {
      database.selected = server.copyWith(url: 'http://selected.onion');
      app.setServer(database.selected);
      final locals = await open(tester);
      await tester.tap(find.text(locals.shareInvidiousLink));
      await tester.pumpAndSettle();
      expect(
          shared.single, {'text': 'http://selected.onion/watch?v=dQw4w9WgXcQ'});
      expect(launched, isEmpty);
    });

    testWidgets('a completed native share cannot dismiss a newer dialog',
        (tester) async {
      shareResult = Completer<String>();
      final locals = await open(tester);
      await tester.tap(find.text(locals.shareInvidiousLink));
      await tester.pump();
      expect(shared, hasLength(1));
      Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      await tester.pump();
      unawaited(showDialog<void>(
          context: tester.element(find.text('Open sharing')),
          builder: (_) => const AlertDialog(title: Text('Keep dialog'))));
      shareResult!.complete('dev.fluttercommunity.plus/share/unavailable');
      await tester.pumpAndSettle();
      expect(find.text('Keep dialog'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final change in ['profile', 'account', 'loading', 'dismissed']) {
      testWidgets('pending share stops after $change changes', (tester) async {
        database.lookup = Completer<Server>();
        final locals = await open(tester);
        await tester.tap(find.text(locals.shareInvidiousLink));
        await tester.pump();
        switch (change) {
          case 'profile':
            database.profileId = 'another-profile';
          case 'account':
            database.selected = server.copyWith(url: 'https://other.example');
          case 'loading':
            app.setGlobalLoading(true);
          case 'dismissed':
            Navigator.of(tester.element(find.byType(BottomSheet))).pop();
            await tester.pumpAndSettle();
        }
        database.lookup!.complete(server);
        await tester.pumpAndSettle();
        expect(shared, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
