import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/music/services/music_listening_history.dart';
import 'package:clipious/music/services/spotify_music_history_candidates.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'collects release aliases and only visible tracks for the active profile',
      () async {
    final database = db = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    final owner = database.forProfile(database.profileId);
    final library = MusicLibraryService.forProfile(owner, owner.profileId);
    await library.save(const MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'sameSong123',
      title: 'Saved song',
      subtitle: 'Artist',
      album: 'Saved release',
    ));
    final other = await database.createProfile('Another listener');
    final otherLibrary = MusicLibraryService.forProfile(database, other.id);
    await otherLibrary.save(const MusicLibraryEntry(
      kind: MusicLibraryKind.song,
      id: 'foreignSong',
      title: 'Other listener’s save',
      subtitle: 'Artist',
    ));

    const tree = 'content://documents/tree/primary%3AMusic';
    const channel = MethodChannel('com.github.dvbeckwitt.videre/local_music');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'getFolder' => {
            'uri': tree,
            'name': 'Music',
            'selectionId': 'approved-source',
          },
        'checkFolderAccess' => true,
        'listTracks' => [
            {
              'uri': '$tree/document/primary%3AMusic%2Fvisible.flac',
              'title': 'Visible track',
              'artist': 'Artist',
              'artPath': '/cache/local-art.jpg',
              'visibilityKey': 'a' * 64,
            },
            {
              'uri': '$tree/document/primary%3AMusic%2Fhidden.flac',
              'title': 'Hidden track',
              'artist': 'Artist',
              'visibilityKey': 'b' * 64,
            },
          ],
        _ => throw MissingPluginException(),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    MusicListeningEvent event(String id, String track, String title) =>
        MusicListeningEvent(
          id: id,
          entry: HistoryVideoCache(
            track,
            title,
            'Artist',
            'https://example.test/private-art',
            musicMetadata: MusicMetadata(
              title: title,
              artist: 'Artist',
              album: 'Prior release',
            ),
          ),
          source: MusicListeningSource.catalog,
        );

    final events = [
      event(
          '00000000-0000-4000-8000-000000000000', 'sameSong123', 'Prior label'),
      event(
          '00000000-0000-4000-8000-000000000001', 'sameSong123', 'Prior label'),
      event('00000000-0000-5000-8000-000000000000', 'priorImport',
          'Imported row'),
    ];
    bool active() => database.profileId == owner.profileId;
    final initial = await spotifyMusicHistoryCandidates(owner, library,
        events: events, isCurrent: active);
    expect(
        initial.map((candidate) => candidate.entry.title),
        unorderedEquals([
          'Saved song',
          'Prior label',
          'Visible track',
          'Hidden track',
        ]));
    final device = LocalMusicLibrary.instance;
    final hidden = device.visibleTracks.firstWhere(
      (track) => track.title == 'Hidden track',
    );
    expect(await device.hideTrack(hidden), isNotNull);

    final filtered = await spotifyMusicHistoryCandidates(owner, library,
        events: events, isCurrent: active);
    expect(
        filtered.map((candidate) => candidate.entry.title),
        unorderedEquals([
          'Saved song',
          'Prior label',
          'Visible track',
        ]));
    final visible = filtered.singleWhere(
      (candidate) => candidate.source == MusicListeningSource.device,
    );
    expect(visible.entry.videoId, startsWith('device:'));
    expect(visible.entry.toJson().toString(), isNot(contains(tree)));
    expect(filtered.map((candidate) => candidate.entry.thumbnail),
        everyElement(isEmpty));
    expect(
      await spotifyMusicHistoryCandidates(owner, otherLibrary,
          events: events, isCurrent: active),
      isEmpty,
    );
  });
}
