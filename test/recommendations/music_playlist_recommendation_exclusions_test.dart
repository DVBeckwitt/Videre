import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/recommendations/music_playlist_recommendation_exclusions.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playlist exclusions are reversible and belong to one profile',
      () async {
    final database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final originalProfile = database.profileId;
    final other = await database.createProfile('Other');
    final exclusions =
        MusicPlaylistRecommendationExclusions.forDatabase(database);
    PlaylistReference playlist(String id, {String? title, String? profile}) =>
        PlaylistReference(
          kind: PlaylistSourceKind.local,
          playlistId: id,
          profileId: profile ?? originalProfile,
          displayTitle: title,
        );
    final first = playlist('local:first', title: 'First title');
    final second = playlist('local:second');
    final firstKey = musicPlaylistRecommendationKey(first);
    final secondKey = musicPlaylistRecommendationKey(second);
    expect(
        musicPlaylistRecommendationKey(
            playlist('local:first', title: 'Renamed')),
        firstKey);
    expect(firstKey, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(isMusicPlaylistRecommendationExcluded(database, firstKey), isFalse);

    var changes = 0;
    exclusions.addListener(() => changes++);
    await Future.wait([
      exclusions.setExcluded(first, excluded: true, isCurrent: () => true),
      exclusions.setExcluded(second, excluded: true, isCurrent: () => true),
      exclusions.setExcluded(first, excluded: false, isCurrent: () => true),
    ]);
    expect(changes, 3);
    expect(isMusicPlaylistRecommendationExcluded(database, firstKey), isFalse);
    expect(isMusicPlaylistRecommendationExcluded(database, secondKey), isTrue);

    await database.useProfile(other.id);
    expect(isMusicPlaylistRecommendationExcluded(database, secondKey), isFalse);
    final otherSecond = playlist('local:second', profile: other.id);
    expect(musicPlaylistRecommendationKey(otherSecond), isNot(secondKey));
    await expectLater(
        exclusions.setExcluded(second, excluded: false, isCurrent: () => true),
        throwsStateError);
    await expectLater(
        exclusions.setExcluded(otherSecond,
            excluded: true, isCurrent: () => false),
        throwsStateError);
    expect(
        isMusicPlaylistRecommendationExcluded(
            database, musicPlaylistRecommendationKey(otherSecond)),
        isFalse);
    await database.useProfile(originalProfile);
    expect(isMusicPlaylistRecommendationExcluded(database, secondKey), isTrue);
  });
}
