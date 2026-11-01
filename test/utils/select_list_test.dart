import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/states/select_list.dart';
import 'package:clipious/utils/views/components/select_list_dialog.dart';
import 'package:clipious/utils/views/tv/components/searchable_dynamic_select_from_list.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('older search results cannot replace the latest query', () async {
    final cubit = SelectListCubit<String>(const SelectListState());
    addTearDown(cubit.close);
    final old = Completer<List<String>>();
    final current = Completer<List<String>>();
    final first = cubit.filterItems((_) => old.future, null, null, 'a');
    final second = cubit.filterItems((_) => current.future, null, null, 'ab');
    current.complete(['current']);
    await second;
    old.complete(['old']);
    await first;
    expect(cubit.state.filteredItems, ['current']);
    expect(cubit.state.loading, isFalse);
  });

  test('stale failures cannot stop a newer search', () async {
    final cubit = SelectListCubit<String>(const SelectListState());
    addTearDown(cubit.close);
    final old = Completer<List<String>>();
    final current = Completer<List<String>>();
    final first = cubit.filterItems((_) => old.future, null, null, 'a');
    final second = cubit.filterItems((_) => current.future, null, null, 'ab');
    old.completeError(StateError('offline'));
    await first;
    expect(cubit.state.loading, isTrue);
    expect(cubit.state.hasError, isFalse);
    current.complete(['current']);
    await second;
    expect(cubit.state.filteredItems, ['current']);
  });

  test('a failed query clears loading and a later query recovers', () async {
    final cubit = SelectListCubit<String>(
        const SelectListState(filteredItems: ['previous']));
    addTearDown(cubit.close);
    await cubit.filterItems(
        (_) async => throw StateError('offline'), null, null, 'first');
    expect(cubit.state.loading, isFalse);
    expect(cubit.state.hasError, isTrue);
    expect(cubit.state.filteredItems, ['previous']);
    await cubit.filterItems((_) async => ['new'], null, null, 'next');
    expect(cubit.state.hasError, isFalse);
    expect(cubit.state.filteredItems, ['new']);
  });

  for (final fails in [false, true]) {
    test('closing ignores pending ${fails ? 'failures' : 'results'}', () async {
      final cubit = SelectListCubit<String>(const SelectListState());
      final response = Completer<List<String>>();
      final search = cubit.filterItems((_) => response.future, null, null, 'a');
      await cubit.close();
      if (fails) {
        response.completeError(StateError('offline'));
      } else {
        response.complete(['result']);
      }
      await search;
      await cubit.filterItems(
          (_) => throw StateError('must not run'), null, null, 'closed');
    });
  }

  test('local filtering supersedes an outstanding remote query', () async {
    final cubit = SelectListCubit<String>(const SelectListState());
    addTearDown(cubit.close);
    final response = Completer<List<String>>();
    final pending = cubit.filterItems((_) => response.future, null, null, 'a');
    await cubit.filterItems(null, (query, value) => value.contains(query),
        ['first', 'second'], 'sec');
    response.complete(['old']);
    await pending;
    expect(cubit.state.filteredItems, ['second']);
  });

  for (final isTv in [false, true]) {
    testWidgets('${isTv ? 'TV' : 'phone'} selector shows recoverable failures',
        (tester) async {
      var fail = true;
      Future<List<String>> search(String query) async {
        if (fail) throw StateError('offline');
        return [query];
      }

      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: isTv
            ? SearchableSelectFromListScreen<String>(
                title: 'Channel',
                fetchItems: search,
                onSelect: (_) {},
                titleBuilder: (item) => item,
                descriptionBuilder: (_) => null,
              )
            : SelectList<String>(
                title: 'Channel',
                values: null,
                asyncSearch: search,
                itemBuilder: (item, _) => Text(item),
                onSelect: (_) {},
              ),
      ));
      Future<void> submit(String query) async {
        if (isTv) {
          tester
              .widget<TvTextField>(find.byType(TvTextField))
              .onSubmitted!(query);
        } else {
          await tester.enterText(find.byType(TextField), query);
        }
        await tester.pumpAndSettle();
      }

      await submit('first');
      expect(find.text('Error'), findsOneWidget);
      fail = false;
      await submit('second');
      expect(find.text('Error'), findsNothing);
      expect(find.text('second'), findsWidgets);
      final controller = isTv
          ? tester.widget<TvTextField>(find.byType(TvTextField)).controller
          : null;
      await tester.pumpWidget(const SizedBox.shrink());
      if (controller != null) {
        expect(() => controller.addListener(() {}), throwsFlutterError);
      }
    });
  }
}
