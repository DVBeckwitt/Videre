import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/search/models/search_date.dart';
import 'package:clipious/search/models/search_duration.dart';
import 'package:clipious/search/models/search_results.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/models/search_suggestion.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/search/views/screens/search.dart';
import 'package:clipious/search/views/tv/screens/search.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _SearchService extends Service {
  final requests = <({
    String query,
    SearchType? type,
    int? page,
    Completer<SearchResults> result
  })>[];
  bool deferred = false;

  @override
  Future<SearchSuggestion> getSearchSuggestion(String query) async =>
      SearchSuggestion(query, ['$query suggestion']);

  @override
  Future<SearchResults> search(String query,
      {SearchType? type,
      int? page,
      SearchSortBy? sortBy,
      SearchDate date = SearchDate.any,
      SearchDuration duration = SearchDuration.any,
      Server? serverOverride,
      bool enrichResults = true}) {
    final result = Completer<SearchResults>();
    requests.add((query: query, type: type, page: page, result: result));
    if (!deferred) result.complete(SearchResults());
    return result.future;
  }
}

void main() {
  late _SearchService fakeService;
  late TestAppCubit app;
  late TestSettingsCubit settings;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    service = fakeService = _SearchService();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
  });

  tearDown(() async {
    await settings.close();
    await app.close();
    await db.close();
  });

  Future<void> mountSearch(WidgetTester tester,
      {String? query, bool? searchNow}) async {
    await tester.pumpWidget(BlocProvider<SettingsCubit>.value(
      value: settings,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TvSearchScreen(query: query, searchNow: searchNow),
      ),
    ));
  }

  Future<void> showSearch(WidgetTester tester) async {
    await mountSearch(tester);
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    field.controller.text = 'dogs';
    await tester.pump(const Duration(milliseconds: 500));
    field.onSubmitted!('dogs');
    await tester.pump();
  }

  for (final searchNow in [false, true]) {
    testWidgets('TV initial query respects searchNow=$searchNow',
        (tester) async {
      await mountSearch(tester, query: 'shared search', searchNow: searchNow);
      await tester.pumpAndSettle();
      final field = tester.widget<TvTextField>(find.byType(TvTextField));
      expect(field.controller.text, 'shared search');
      expect(fakeService.requests.map((request) => request.query),
          searchNow ? ['shared search', 'shared search', 'shared search'] : []);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('TV suggestions immediately replace all result lists',
      (tester) async {
    await showSearch(tester);
    await tester.pumpAndSettle();
    expect(fakeService.requests.map((r) => r.query), ['dogs', 'dogs', 'dogs']);

    final button = find.ancestor(
      of: find.text('dogs suggestion'),
      matching: find.byType(TvButton),
    );
    tester.widget<TvButton>(button).onPressed!(tester.element(button));
    await tester.pump();
    await tester.pump();
    expect(fakeService.requests.map((r) => r.query), [
      'dogs',
      'dogs',
      'dogs',
      'dogs suggestion',
      'dogs suggestion',
      'dogs suggestion',
    ]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV paste allows cancellation or searching the URL as text',
      (tester) async {
    await tester.runAsync(() async {
      await db.upsertServer(
          const Server(url: 'https://instance.example', inUse: true));
      await app.initState();
    });
    await mountSearch(tester);
    const address = 'https://other.example/playlist?list=PLmix';
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    Future<void> submitFromKeyboard() async {
      final navigator = Navigator.of(tester.element(find.byType(TvTextField)));
      unawaited(navigator.push<void>(MaterialPageRoute(
        builder: (_) => TvTextFieldScreen(
          controller: field.controller,
          textInputAction: TextInputAction.search,
          onSubmitted: field.onSubmitted,
        ),
      )));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), address);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
    }

    await submitFromKeyboard();
    expect(fakeService.requests, isEmpty);
    final dialog = find.byType(AlertDialog);
    final locals = MaterialLocalizations.of(tester.element(dialog));
    await tester.tap(find.text(locals.cancelButtonLabel));
    await tester.pumpAndSettle();
    expect(fakeService.requests, isEmpty);
    expect(field.controller.text, address);

    await submitFromKeyboard();
    await tester.tap(find.text('Search as text'));
    await tester.pumpAndSettle();
    expect(fakeService.requests.map((request) => request.query),
        [address, address, address]);
    expect(db.getSearchHistory(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV section headings belong to the current submission',
      (tester) async {
    fakeService.deferred = true;
    await showSearch(tester);
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    final requests = fakeService.requests;
    expect(requests, hasLength(3));

    Future<void> submit(String query) async {
      field.controller.text = query;
      field.onSubmitted!(query);
      await tester.pump();
    }

    void finish(int offset, {Channel? channel}) {
      for (final request in requests.skip(offset).take(3)) {
        final results = SearchResults();
        if (channel != null && request.type == SearchType.channel) {
          results.channels.add(channel);
        }
        request.result.complete(results);
      }
    }

    final channel = Channel('Creator', 'UCabcdefghijklmnopqrstuv', '', null, [],
        0, null, null, false, null, '', null, null);
    await submit('birds');
    expect(requests, hasLength(6));
    finish(3, channel: channel);
    await tester.pump();
    expect(find.text('Channels'), findsOneWidget);

    await submit('dogs');
    expect(requests, hasLength(9));
    final headingWhileLoading = find.text('Channels').evaluate().isNotEmpty;
    finish(6);
    await tester.pump();
    finish(0, channel: channel);
    await tester.pump();
    final headingAfterOldResult = find.text('Channels').evaluate().isNotEmpty;
    expect((headingWhileLoading, headingAfterOldResult), (false, false));
    expect(find.text('Creator'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('TV video search can page past locally hidden results',
      (tester) async {
    fakeService.deferred = true;
    await showSearch(tester);
    final requests = fakeService.requests;
    expect(requests, hasLength(3));
    for (final request in requests) {
      final results = SearchResults();
      if (request.type == SearchType.video) {
        results.videos = List.generate(
          searchPageSize,
          (i) => Video(
              videoId: 'hidden-$i', title: 'Hidden result', filterHide: true),
        );
      }
      request.result.complete(results);
    }
    await tester.pumpAndSettle();
    expect(find.text('Hidden result'), findsNothing);

    final button = find.ancestor(
      of: find.text('Load more'),
      matching: find.byType(TvButton),
    );
    tester.widget<TvButton>(button).onPressed!(tester.element(button));
    await tester.pump();
    expect(requests, hasLength(4));
    expect(requests.last.type, SearchType.video);
    expect(requests.last.page, 2);
    requests.last.result.complete(SearchResults());
    await tester.pumpAndSettle();
    expect(find.text('Load more'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('TV search ignores results completed after leaving the screen',
      (tester) async {
    fakeService.deferred = true;
    await showSearch(tester);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fakeService.requests, hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
    for (final request in fakeService.requests) {
      request.result.complete(SearchResults());
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
