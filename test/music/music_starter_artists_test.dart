import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_starter_artists.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test('choices and skip persist separately for each profile', () async {
    final factory = newDatabaseFactoryMemory();
    var database = SembastSqfDb(await factory.openDatabase('starter-artists'));
    await database.getProfiles();
    final firstId = database.profileId;
    final second = await database.createProfile('Second listener');
    final first = MusicStarterArtists(database, firstId);
    final firstListener = MusicStarterArtists(database, firstId);
    final secondListener = MusicStarterArtists(database, second.id);
    final firstChanges = <List<String>?>[];
    final secondChanges = <List<String>?>[];
    firstListener.changes
        .addListener(() => firstChanges.add(firstListener.picks));
    secondListener.changes
        .addListener(() => secondChanges.add(secondListener.picks));

    expect(first.picks, isNull);
    await first.save([
      ' Björk ',
      'BJORK',
      '  A\tTribe\n Called Quest  ',
      'Nina Simone',
      'Fourth artist'
    ]);
    expect(firstChanges, [
      ['Björk', 'A Tribe Called Quest', 'Nina Simone']
    ]);
    await database.useProfile(second.id);
    expect(secondListener.picks, isNull);
    await secondListener.save([]);
    expect(secondChanges.single, isEmpty);
    await first.save(['Stale edit']);
    expect(firstChanges, hasLength(1));
    await database.close();

    database = SembastSqfDb(await factory.openDatabase('starter-artists'));
    addTearDown(database.close);
    expect(MusicStarterArtists(database, second.id).picks, isEmpty);
    await database.useProfile(firstId);
    final reopened = MusicStarterArtists(database, firstId);
    expect(reopened.picks, ['Björk', 'A Tribe Called Quest', 'Nina Simone']);
    await reopened.save(['Nina Simone']);
    expect(reopened.picks, ['Nina Simone']);
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
    ]) {
      await database
          .saveSetting(SettingsValue(musicStarterArtistsSettingName, value));
      expect(starter.picks, isNull, reason: value);
    }
    await expectLater(starter.save(['\u0000']), throwsFormatException);
    expect(starter.picks, isNull);
    await starter.save(['A valid choice']);
    expect(starter.picks, ['A valid choice']);
  });

  test('matching uses whole individual artist names and credits', () {
    final bjork = MusicStarterArtists.artistKey('  BJO\u0308RK\u00a0');
    expect(bjork, 'bjork');
    expect(MusicStarterArtists.cleanName('x' * 101), isNull);
    expect(MusicStarterArtists.cleanName('🎵' * 100), '🎵' * 100);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(videoId: 'recording01', title: 'Song', artists: [
              'Another Artist',
              'Björk',
            ]),
            {bjork}),
        isTrue);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording02',
                title: 'Song',
                artistLinks: [
                  MusicArtist(id: 'artist', name: 'Björk'),
                ]),
            {bjork}),
        isTrue);
    expect(
        MusicStarterArtists.matches(
            const MusicTrack(
                videoId: 'recording03',
                title: 'Björk tribute',
                artists: ['The Björk Tribute Band']),
            {bjork}),
        isFalse);
  });
}
