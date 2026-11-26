import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_artist_mix_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _first = MusicArtist(id: 'UCaaaaaaaaaaaaaaaaaaaaaa', name: 'First');
const _second = MusicArtist(id: 'UCbbbbbbbbbbbbbbbbbbbbbb', name: 'Second');
const _third = MusicArtist(id: 'UCcccccccccccccccccccccc', name: 'Third');
const _fourth = MusicArtist(id: 'UCdddddddddddddddddddddd', name: 'Fourth');

class _Catalog extends MusicCatalogService {
  final requests = <({
    String query,
    bool Function()? isCurrent,
    Completer<MusicCatalogSearchPage> response,
  })>[];

  @override
  Future<MusicCatalogSearchPage> searchPage(
      String query, MusicCatalogSearchType type, int page,
      {bool Function()? isCurrent,
      void Function(List<MusicCatalogArtistHit>)? onArtistPreview}) {
    expect(type, MusicCatalogSearchType.channels);
    expect(page, 1);
    final response = Completer<MusicCatalogSearchPage>();
    requests.add((query: query, isCurrent: isCurrent, response: response));
    return response.future;
  }

  void complete(int index, List<MusicArtist> artists) {
    requests[index].response.complete(MusicCatalogSearchPage(
        hits: artists.map(MusicCatalogChannelHit.new).toList(), rawKeys: []));
  }
}

void main() {
  late _Catalog catalog;
  List<MusicArtist>? selection;

  setUp(() {
    final previousCatalog = musicCatalogService;
    catalog = _Catalog();
    musicCatalogService = catalog;
    selection = null;
    addTearDown(() => musicCatalogService = previousCatalog);
  });

  Future<void> openPicker(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  selection = await showMusicArtistMixPicker(context, _first,
                      isCurrent: () => true);
                },
                child: const Text('Open'))),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
  }

  Finder chip(MusicArtist artist) => find.byKey(ValueKey(artist.id));
  Finder result(MusicArtist artist) =>
      find.byKey(ValueKey('result-${artist.id}'));

  testWidgets('keeps unique selected channels across searches and caps seeds',
      (tester) async {
    await openPicker(tester);
    expect(tester.widget<FilterChip>(chip(_first)).selected, isTrue);

    await search(tester, '  second  ');
    expect(catalog.requests.single.query, 'second');
    catalog.complete(0, [
      MusicArtist(id: '/channel/${_second.id}', name: 'Second'),
      const MusicArtist(id: 'invalid', name: 'Invalid'),
      _second,
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsOneWidget);
    await tester.tap(result(_second));
    await tester.pumpAndSettle();

    await search(tester, 'more');
    catalog.complete(1, [_third, _fourth]);
    await tester.pumpAndSettle();
    expect(chip(_second), findsOneWidget);
    await tester.tap(result(_third));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(result(_fourth)).onChanged, isNull);

    await tester.tap(chip(_first));
    await tester.pumpAndSettle();
    await tester.tap(result(_fourth));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(selection?.map((artist) => artist.id),
        [_second.id, _third.id, _fourth.id]);
  });

  testWidgets('a new artist search cancels the previous request',
      (tester) async {
    await openPicker(tester);
    await search(tester, 'older');
    expect(catalog.requests[0].isCurrent?.call(), isTrue);
    await search(tester, 'current');
    expect(catalog.requests[0].isCurrent?.call(), isFalse);
    catalog.complete(1, [_third]);
    catalog.complete(0, [_second]);
    await tester.pumpAndSettle();
    expect(result(_second), findsNothing);
    expect(result(_third), findsOneWidget);
  });
}
