import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_lyrics_match.dart';
import 'package:clipious/music/services/lrc_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_corrections.dart';
import 'package:clipious/music/services/music_timed_lyrics_draft.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const videoId = 'abcdefghijk';
  const anotherVideoId = 'ABCDEFGHIJK';
  const settingKey = 'music-lyrics-correction-$videoId';
  late SembastSqfDb database;
  late SembastSqfDb owner;
  late MusicLyricsCorrections store;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    addTearDown(database.close);
    owner = database.forProfile(database.profileId);
    store = MusicLyricsCorrections(owner);
  });

  test('a correction is bound to the original profile and recording', () async {
    const selected = MusicLyricsCorrection(
        MusicLyrics.plain('Private words', source: 'LRCLIB'));
    final second = await database.createProfile('Second');
    await database.useProfile(second.id);
    final other = MusicLyricsCorrections(database.forProfile(second.id));

    await store.save(videoId, selected);
    final reopened = MusicLyricsCorrections(owner).read(videoId)!;
    expect(reopened.lyrics.text, 'Private words');
    expect(reopened.lyrics.source, 'LRCLIB');
    expect(reopened.edited, isFalse);
    expect(store.read(anotherVideoId), isNull);
    expect(other.read(videoId), isNull);
    expect((await owner.exportBackup()).encode(),
        isNot(contains('Private words')));
  });

  test('an edited timed match retains original source and simultaneous cues',
      () async {
    const cues = [
      (start: Duration(milliseconds: 3105), text: 'First'),
      (start: Duration(milliseconds: 3105), text: 'Second'),
      (start: Duration(milliseconds: 8001), text: 'First'),
    ];
    await store.save(
        videoId,
        const MusicLyricsCorrection(MusicLyrics.synced(cues, source: 'LRCLIB'),
            edited: true));

    final result = store.read(videoId)!;
    expect(result.lyrics.kind, MusicLyricsKind.synced);
    expect(result.lyrics.cues, cues);
    expect(result.lyrics.source, 'LRCLIB');
    expect(result.edited, isTrue);
  });

  test('a selected timed match retains signed cue, word and break starts',
      () async {
    final parsed = parseEnhancedLrc('[offset:+500]\n'
        '[00:00.100]  <00:00.100>Hello <00:00.400>again  \n'
        'Translation\n'
        '[00:00.450][00:03.250]\n'
        '[00:08][00:12]Second line\n'
        '  Shared continuation  ');
    await store.save(
        videoId,
        MusicLyricsCorrection(MusicLyrics.synced(parsed.lines,
            wordsByCue: parsed.wordsByCue,
            displayTextByCue: parsed.displayTextByCue,
            breakStarts: parsed.breakStarts)));

    final reopened = store.read(videoId)!.lyrics;
    expect(reopened.cues, parsed.lines);
    expect(reopened.wordsByCue, parsed.wordsByCue);
    expect(reopened.displayTextByCue, parsed.displayTextByCue);
    expect(musicTimedLyricsDraftFrom(reopened, includeWordTiming: false),
        contains('  Hello again  \nTranslation'));
    expect(reopened.breakStarts, parsed.breakStarts);
    expect(reopened.breakStarts.first, const Duration(milliseconds: -50));
    expect(reopened.cues.first.start, const Duration(milliseconds: -400));
    expect(
        reopened.wordsByCue[0]!.last.start, const Duration(milliseconds: -100));

    await owner.saveSetting(SettingsValue(settingKey,
        '{"kind":"synced","lines":["A"],"cues":[[1000,0]],"words":[[0,1000,0,5]]}'));
    expect(store.read(videoId)!.lyrics.cues.single.text, 'A');
    expect(store.read(videoId)!.lyrics.wordsByCue, isEmpty);

    await owner.saveSetting(SettingsValue(settingKey,
        '{"kind":"synced","lines":["A"],"cues":[[1000,0]],"displayText":{"B\\nMismatch":[0]}}'));
    expect(store.read(videoId)!.lyrics.cues.single.text, 'A');
    expect(store.read(videoId)!.lyrics.displayTextByCue, isEmpty);
    expect(store.read(videoId)!.lyrics.breakStarts, isEmpty);
  });

  test('unusable optional breaks preserve valid stored cues', () async {
    await owner.saveSetting(SettingsValue(settingKey,
        '{"kind":"synced","lines":["A"],"cues":[[1000,0]],"breaks":[3000,2000]}'));
    final lyrics = store.read(videoId)!.lyrics;
    expect(lyrics.cues.single.text, 'A');
    expect(lyrics.breakStarts, isEmpty);
  });

  test('repeated plain cue text fits storage without re-enabling seeking',
      () async {
    final repeated = 'a' * (maxLyricsCharacters ~/ 2);
    final cues = List<MusicLyricCue>.generate(
        3000, (index) => (start: Duration(seconds: index), text: repeated));
    await store.save(videoId,
        MusicLyricsCorrection(MusicLyrics.plainCues(cues, source: 'LRCLIB')));

    expect(owner.getSettings(settingKey)!.value.length,
        lessThan(maxLyricsCharacters));
    final result = store.read(videoId)!;
    expect(result.lyrics.kind, MusicLyricsKind.plain);
    expect(result.lyrics.text, isNull);
    expect(result.lyrics.cues, cues);
  });

  test('a discarded match is explicit until automatic matching is restored',
      () async {
    expect(store.read(videoId), isNull);
    await store.save(
        videoId,
        const MusicLyricsCorrection(
            MusicLyrics.instrumental(source: 'LRCLIB')));
    expect(store.read(videoId)!.lyrics.kind, MusicLyricsKind.instrumental);
    await store.save(
        videoId, const MusicLyricsCorrection(MusicLyrics.unavailable()));
    expect(store.read(videoId)!.lyrics.kind, MusicLyricsKind.unavailable);
    await store.clear(videoId);
    expect(store.read(videoId), isNull);
  });

  test('invalid IDs and corrupt records cannot become usable corrections',
      () async {
    const invalidId = 'abcdefghij\n';
    const correction = MusicLyricsCorrection(MusicLyrics.unavailable());
    expect(store.read(invalidId), isNull);
    await expectLater(store.save(invalidId, correction), throwsArgumentError);
    await expectLater(store.clear(invalidId), throwsArgumentError);

    await owner.saveSetting(SettingsValue(settingKey, '['));
    expect(store.read(videoId), isNull);
    await owner.saveSetting(SettingsValue(settingKey,
        '{"kind":"synced","lines":["A"],"cues":[[2000,0],[1000,0]]}'));
    expect(store.read(videoId), isNull);
    await owner.saveSetting(SettingsValue(
        settingKey, '{"kind":"plain","text":"word","source":"spoofed.com"}'));
    expect(store.read(videoId)!.lyrics.source, isNull);
  });
}
