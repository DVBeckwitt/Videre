import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/search/models/search_date.dart';
import 'package:clipious/search/models/search_duration.dart';
import 'package:clipious/search/models/search_results.dart';
import 'package:clipious/search/models/search_sort_by.dart';
import 'package:clipious/search/models/search_suggestion.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/search/views/tv/screens/search.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_app_cubit.dart';
import '../test_settings_cubit.dart';

class _SearchService extends Service {
  final requests = <({String query, Completer<SearchResults> result})>[];
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
      SearchDuration duration = SearchDuration.any}) {
    final result = Completer<SearchResults>();
    requests.add((query: query, result: result));
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

  Future<void> showSearch(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<SettingsCubit>.value(
      value: settings,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const TvSearchScreen(),
      ),
    ));
    final field = tester.widget<TvTextField>(find.byType(TvTextField));
    field.controller.text = 'dogs';
    await tester.pump(const Duration(milliseconds: 500));
    field.onSubmitted!('dogs');
    await tester.pump();
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
