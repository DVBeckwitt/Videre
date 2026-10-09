import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/router.dart';
import 'package:clipious/search/models/search_date.dart';
import 'package:clipious/search/models/search_duration.dart';
import 'package:clipious/search/models/search_results.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/models/search_suggestion.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/search/states/search.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _SuggestionsService extends Service {
  final requests = <({String query, Completer<SearchSuggestion> response})>[];

  @override
  Future<SearchSuggestion> getSearchSuggestion(String query) {
    final response = Completer<SearchSuggestion>();
    requests.add((query: query, response: response));
    return response.future;
  }

  void complete(int index) {
    final request = requests[index];
    request.response.complete(
        SearchSuggestion(request.query, ['${request.query} suggestion']));
  }

  @override
  Future<SearchResults> search(String query,
          {SearchType? type,
          int? page,
          SearchSortBy? sortBy,
          SearchDate date = SearchDate.any,
          SearchDuration duration = SearchDuration.any}) async =>
      SearchResults();
}

void main() {
  late _SuggestionsService suggestions;
  late TestAppCubit app;
  late TestSettingsCubit settings;
  late SearchCubit search;

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    service = suggestions = _SuggestionsService();
    app = TestAppCubit(AppState(0, null, HomeLayout()));
    app.intentDataStreamSubscription = const Stream.empty().listen((_) {});
    settings = TestSettingsCubit(SettingsState.init(), app);
    search = SearchCubit(SearchState.init(query: 'cats'), settings);
  });

  tearDown(() async {
    if (!search.isClosed) await search.close();
    await settings.close();
    await app.close();
    await db.close();
  });

  testWidgets('moving the caret keeps submitted results visible',
      (tester) async {
    await search.search('cats');
    search.state.queryController.selection =
        const TextSelection.collapsed(offset: 2);
    expect(search.state.showResults, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(suggestions.requests, isEmpty);
  });

  testWidgets('older suggestions cannot replace the current query',
      (tester) async {
    search.state.queryController.text = 'dogs';
    await tester.pump(const Duration(milliseconds: 500));
    search.state.queryController.text = 'birds';
    await tester.pump(const Duration(milliseconds: 500));
    suggestions.complete(1);
    await tester.pump();
    suggestions.complete(0);
    await tester.pump();
    expect(search.state.suggestions, ['birds suggestion']);
  });

  testWidgets('suggestion errors leave typing and submitting usable',
      (tester) async {
    search.state.queryController.text = 'dogs';
    await tester.pump(const Duration(milliseconds: 500));
    suggestions.requests.single.response.completeError(Exception('offline'));
    await tester.pump();
    expect(search.state.suggestions, isEmpty);
    search.state.queryController.text = 'birds';
    await tester.pump(const Duration(milliseconds: 500));
    suggestions.complete(1);
    await tester.pump();
    expect(search.state.suggestions, ['birds suggestion']);
    await search.search('birds');
    expect(search.state.showResults, isTrue);
  });

  testWidgets('closing cancels suggestions that have not started',
      (tester) async {
    search.state.queryController.text = 'dogs';
    await search.close();
    await tester.pump(const Duration(milliseconds: 500));
    expect(suggestions.requests, isEmpty);
  });

  testWidgets('closing ignores suggestions already in flight', (tester) async {
    search.state.queryController.text = 'dogs';
    await tester.pump(const Duration(milliseconds: 500));
    await search.close();
    suggestions.complete(0);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('each search owns its pending suggestions', (tester) async {
    final second = SearchCubit(SearchState.init(), settings);
    addTearDown(second.close);
    search.state.queryController.text = 'dogs';
    second.state.queryController.text = 'birds';
    await tester.pump(const Duration(milliseconds: 500));
    expect(suggestions.requests.map((request) => request.query),
        ['dogs', 'birds']);
    suggestions.complete(0);
    suggestions.complete(1);
    await tester.pump();
  });

  testWidgets('clearing removes suggestions without requesting an empty query',
      (tester) async {
    search.state.queryController.text = 'dogs';
    await tester.pump(const Duration(milliseconds: 500));
    suggestions.complete(0);
    await tester.pump();
    expect(search.searchCleared(), isFalse);
    expect(search.state.suggestions, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(suggestions.requests, hasLength(1));
  });

  testWidgets(
      'choosing a suggestion dismisses the keyboard and clearing refocuses',
      (tester) async {
    final router = RootStackRouter.build(routes: [
      AutoRoute(page: SearchRoute.page, path: '/', children: [
        AutoRoute(page: SearchVideoRoute.page),
        AutoRoute(page: SearchChannelRoute.page),
        AutoRoute(page: SearchPlaylistRoute.page),
      ]),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(BlocProvider<SettingsCubit>.value(
      value: settings,
      child: MaterialApp.router(
        routerConfig: router.config(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dogs');
    await tester.pump(const Duration(milliseconds: 500));
    suggestions.complete(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('dogs suggestion'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isFalse);
    await tester.tap(find.byIcon(Icons.clear));
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, isEmpty);
    expect(field.focusNode.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
