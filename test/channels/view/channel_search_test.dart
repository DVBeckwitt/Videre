import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/views/components/channel_search.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../test_app_cubit.dart';
import '../../test_player_cubit.dart';
import '../../test_settings_cubit.dart';

const _channel = 'UCabcdefghijklmnopqrstuv';
const _server = Server(url: 'https://example.invalid');
const _queryField = ValueKey('channel-search-query');

http.Response _page(List<Object> values) => http.Response(
      jsonEncode(values),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, String> _video(String title) => {
      'type': 'video',
      'videoId': 'search00001',
      'title': title,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SembastSqfDb database;
  late Service previousService;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late TestPlayerCubit player;

  setUp(() async {
    previousService = service;
    database = await SembastSqfDb.createInMemory();
    db = database;
    await database.upsertServer(_server);
    await database.useServer(_server);
    app = TestAppCubit(AppState(0, _server, HomeLayout()));
    app.intentDataStreamSubscription =
        const Stream<void>.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    player = TestPlayerCubit(PlayerState.init(null), settings);
  });

  tearDown(() async {
    service = previousService;
    await player.close();
    await settings.close();
    await app.close();
    await database.close();
  });

  Future<void> open(WidgetTester tester, ScrollController uploads) async {
    await tester.pumpWidget(MultiBlocProvider(
      providers: [
        BlocProvider<AppCubit>.value(value: app),
        BlocProvider<SettingsCubit>.value(value: settings),
        BlocProvider<PlayerCubit>.value(value: player),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChannelSearchShell(
          channelId: _channel,
          builder: (context, search) => Scaffold(
            appBar: AppBar(
              actions: [
                IconButton(
                    tooltip: 'Search channel',
                    onPressed: search,
                    icon: const Icon(Icons.search)),
              ],
            ),
            body: ListView.builder(
              controller: uploads,
              itemCount: 40,
              itemBuilder: (context, index) =>
                  SizedBox(height: 90, child: Text('Upload $index')),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search channel'));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(_queryField), query);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
  }

  testWidgets('search is explicit and continues past a playlist-only page',
      (tester) async {
    final requests = <Uri>[];
    service = Service(httpClient: MockClient((request) async {
      requests.add(request.url);
      return request.url.queryParameters['page'] == '1'
          ? _page([
              {'type': 'playlist', 'playlistId': 'PLtest'}
            ])
          : _page([_video('Matching video')]);
    }));
    final uploads = ScrollController(initialScrollOffset: 450);
    addTearDown(uploads.dispose);
    await open(tester, uploads);
    expect(uploads.offset, 450);
    await tester.enterText(find.byKey(_queryField), 'nature & science');
    await tester.pump(const Duration(seconds: 1));
    expect(requests, isEmpty);

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(requests.single.origin, _server.url);
    expect(requests.single.path, '/api/v1/channels/$_channel/search');
    expect(requests.single.queryParameters['q'], 'nature & science');
    expect(requests.single.queryParameters['local'], 'true');
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(
        requests.map((request) => request.queryParameters['page']), ['1', '2']);
    expect(find.text('Matching video'), findsOneWidget);

    await Navigator.of(tester.element(find.byKey(_queryField))).maybePop();
    await tester.pumpAndSettle();
    expect(find.byKey(_queryField), findsNothing);
    expect(uploads.offset, 450);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a late answer cannot replace a newer channel query',
      (tester) async {
    final oldResponse = Completer<http.Response>();
    final queries = <String?>[];
    service = Service(httpClient: MockClient((request) async {
      final query = request.url.queryParameters['q'];
      queries.add(query);
      if (query == 'old') return oldResponse.future;
      return _page([_video('Current result')]);
    }));
    final uploads = ScrollController();
    addTearDown(uploads.dispose);
    await open(tester, uploads);
    await submit(tester, 'old');
    expect(queries, ['old']);
    await submit(tester, 'new');
    await tester.pumpAndSettle();
    expect(queries, ['old', 'new']);
    expect(find.text('Current result'), findsOneWidget);
    oldResponse.complete(_page([_video('Retired result')]));
    await tester.pumpAndSettle();
    expect(find.text('Retired result'), findsNothing);
    expect(find.text('Current result'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
