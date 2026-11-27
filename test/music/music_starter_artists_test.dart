import 'dart:async';
import 'dart:convert';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/services/music_starter_artists.dart';
import 'package:clipious/music/views/components/music_starter_artists.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/models/image_object.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

const _server = Server(url: 'https://instance.example');
const _firstId = 'UCaaaaaaaaaaaaaaaaaaaaaa';
const _secondId = 'UCbbbbbbbbbbbbbbbbbbbbbb';
const _thirdId = 'UCcccccccccccccccccccccc';
const _approvedArtwork = 'https://yt3.ggpht.com/favorite=s88';

MusicStarterArtistPick _pick(String id, String name) =>
    MusicStarterArtistPick.fromCatalog(
        MusicArtist(id: id, name: name), _server)!;

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, _server, HomeLayout(), profileId: db.profileId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreviewCatalog extends MusicCatalogService {
  final completion = Completer<MusicCatalogSearchPage>();
  void Function(List<MusicCatalogArtistHit>)? preview;

  @override
  Future<MusicCatalogSearchPage> searchPage(
    String query,
    MusicCatalogSearchType type,
    int page, {
    bool Function()? isCurrent,
    void Function(List<MusicCatalogArtistHit>)? onArtistPreview,
  }) {
    preview = onArtistPreview;
    return completion.future;
  }
}

void main() {
  testWidgets('starter artists show early results and keep them on failure',
      (tester) async {
    db = (await tester.runAsync(SembastSqfDb.createInMemory))!;
    addTearDown(db.close);
    final app = _App();
    addTearDown(app.close);
    final catalog = _PreviewCatalog();
    final previousCatalog = musicCatalogService;
    musicCatalogService = catalog;
    addTearDown(() => musicCatalogService = previousCatalog);
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MusicStarterArtistsSection()),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('music-starter-artists-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Artist');
    await tester.pump(const Duration(milliseconds: 350));

    const hit =
        MusicCatalogArtistHit(MusicArtist(id: _firstId, name: 'Early Artist'));
    catalog.preview?.call([hit, hit]);
    await tester.pump();
    final result =
        find.byKey(const ValueKey('music-starter-artist-result-$_firstId'));
    expect(catalog.completion.isCompleted, isFalse);
    expect(result, findsOneWidget);

    catalog.completion.completeError(const MusicCatalogException('Failed'));
    await tester.pumpAndSettle();
    expect(result, findsOneWidget);
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Early Artist'), findsOneWidget);
  });

  test('catalog identities and legacy choices persist per profile', () async {
    final factory = newDatabaseFactoryMemory();
    var database = SembastSqfDb(await factory.openDatabase('starter-artists'));
    await database.getProfiles();
    final firstProfile = database.profileId;
    final secondProfile = await database.createProfile('Second listener');
    final first = MusicStarterArtists(database, firstProfile);
    final firstListener = MusicStarterArtists(database, firstProfile);
    final second = MusicStarterArtists(database, secondProfile.id);
    expect(first.picks, isNull);

    await database.saveSetting(SettingsValue(musicStarterArtistsSettingName,
        jsonEncode(['  A\tTribe\n Called Quest  '])));
    final legacy = first.picks!.single;
    expect(legacy.name, 'A Tribe Called Quest');
    expect(legacy.catalogId, isNull);
    expect(legacy.thumbnails, isEmpty);

    final firstChanges = <List<MusicStarterArtistPick>?>[];
    final secondChanges = <List<MusicStarterArtistPick>?>[];
    firstListener.changes
        .addListener(() => firstChanges.add(firstListener.picks));
    second.changes.addListener(() => secondChanges.add(second.picks));

    final firstPick = MusicStarterArtistPick.fromCatalog(
        MusicArtist(id: _firstId, name: ' Björk ', thumbnails: [
          ImageObject('default', _approvedArtwork, 88, 88),
        ]),
        _server)!;
    final secondPick = _pick(_secondId, 'Björk');
    await first.save([
      legacy,
      firstPick,
      _pick(_firstId, 'Björk alternative spelling'),
      secondPick,
      _pick(_thirdId, 'Fourth artist'),
    ]);
    expect(firstChanges.single!.map((pick) => pick.name),
        ['A Tribe Called Quest', 'Björk', 'Björk']);
    expect(firstChanges.single!.map((pick) => pick.catalogId),
        [null, _firstId, _secondId]);
    expect(firstChanges.single![1].thumbnails.single.url, _approvedArtwork);
    expect(firstChanges.single![2].thumbnails, isEmpty);

    await database.useProfile(secondProfile.id);
    expect(second.picks, isNull);
    await second.save([]);
    expect(secondChanges.single, isEmpty);
    await first.save([_pick(_thirdId, 'Stale edit')]);
    expect(firstChanges, hasLength(1));
    await database.close();

    database = SembastSqfDb(await factory.openDatabase('starter-artists'));
    addTearDown(database.close);
    expect(MusicStarterArtists(database, secondProfile.id).picks, isEmpty);
    await database.useProfile(firstProfile);
    final reopened = MusicStarterArtists(database, firstProfile);
    expect(reopened.picks!.map((pick) => pick.key),
        [legacy.key, firstPick.key, secondPick.key]);
    expect(reopened.picks![1].thumbnails.single.url, _approvedArtwork);
    await reopened.save([secondPick]);
    expect(reopened.picks!.single.catalogId, _secondId);
    await reopened.save([]);
    expect(reopened.picks, isEmpty);
  });

  test('malformed settings cannot imply a choice or skip', () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final starter = MusicStarterArtists(database, database.profileId);

    for (final value in [
      'garbage',
      '{}',
      '[1]',
      '["Valid", "  "]',
      '["Björk", "BJORK"]',
      '["One", "Two", "Three", "Four"]',
      '[{"id":"name-only","name":"Valid"}]',
      '[{"id":"$_firstId","name":"One"},{"id":"$_firstId","name":"Two"}]',
    ]) {
      await database
          .saveSetting(SettingsValue(musicStarterArtistsSettingName, value));
      expect(starter.picks, isNull, reason: value);
    }
    expect(
        MusicStarterArtistPick.fromCatalog(
            const MusicArtist(id: 'not a channel', name: 'Artist'), _server),
        isNull);
    expect(
        MusicStarterArtistPick.fromCatalog(
            const MusicArtist(id: _firstId, name: '\u0000'), _server),
        isNull);
  });

  test('catalog picks keep approved artwork and allow missing artwork', () {
    final pick = MusicStarterArtistPick.fromCatalog(
        MusicArtist(id: _firstId, name: 'Artist', thumbnails: [
          ImageObject(null, 'https://other.example/picture.jpg', 88, 88),
          ImageObject(null, 'https://person@instance.example/avatar', 88, 88),
          ImageObject(null, _approvedArtwork, 88, 88),
          ImageObject(
              null, 'https://instance.example/ggpht/favorite=s88', 88, 88),
          ImageObject(null, '/ggpht/favorite=s44', 44, 44),
        ]),
        _server)!;
    expect(pick.thumbnails.map((image) => image.url),
        [_approvedArtwork, '/ggpht/favorite=s44']);
    expect(_pick(_secondId, 'Second Artist').thumbnails, isEmpty);
  });

  test('legacy matching uses whole individual artist names and credits',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    await database.saveSetting(SettingsValue(
        musicStarterArtistsSettingName, jsonEncode(['  BJO\u0308RK\u00a0'])));
    final picks = MusicStarterArtists(database, database.profileId).picks!;
    expect(MusicStarterArtists.artistKey(picks.single.name), 'bjork');
    expect(MusicStarterArtists.cleanName('x' * 101), isNull);
    expect(MusicStarterArtists.cleanName('🎵' * 100), '🎵' * 100);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(videoId: 'recording01', title: 'Song', artists: [
              'Another Artist',
              'Björk',
            ]),
            picks),
        isTrue);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording02',
                title: 'Song',
                artistLinks: [
                  MusicArtist(id: _firstId, name: 'Björk'),
                ]),
            picks),
        isTrue);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording03',
                title: 'Björk tribute',
                artists: ['The Björk Tribute Band']),
            picks),
        isFalse);
  });

  test('catalog matching uses the selected ID even when names collide', () {
    final selected = [_pick(_secondId, 'Shared Name')];
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording01',
                title: 'Song',
                artistCredits: [
                  MusicArtistCredit(name: 'Shared Name', id: _firstId),
                ]),
            selected),
        isFalse);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording02',
                title: 'Song',
                artists: ['Shared Name']),
            selected),
        isFalse);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording03',
                title: 'Song',
                artistCredits: [
                  MusicArtistCredit(name: 'Renamed Artist', id: _secondId),
                ]),
            selected),
        isTrue);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording04',
                title: 'Song',
                artistLinks: [
                  MusicArtist(name: 'Renamed Artist', id: _secondId),
                ]),
            selected),
        isTrue);
  });
}
