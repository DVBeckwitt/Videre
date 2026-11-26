import 'dart:async';

import 'package:clipious/music/models/music_current_cue.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('videre/music_lyrics_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const first = (positionMs: 1000, text: 'First line', active: true);
  const second = (positionMs: 2500, text: 'Second line', active: true);
  late MusicLyricsWidget widget;
  late MusicLyricsWidgetPlayback? playback;
  late List<Map<Object?, Object?>?> updates;
  late List<Duration> requestedSeeks;
  late bool Function() canExecuteSeek;

  MusicLyricsWidgetPlayback song({
    String profile = 'profile-one',
    String occurrence = 'queue-one',
    int timeline = 1,
    List<MusicLyricsWidgetRow> rows = const [first],
  }) =>
      (
        owner: (profile, occurrence),
        timeline: timeline,
        title: 'Same title',
        rows: rows,
      );

  Future<bool> tap(Object? token, Object? positionMs) async {
    final reply = Completer<bool>();
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('seek', {'token': token, 'positionMs': positionMs}),
      ),
      (data) => reply.complete(channel.codec.decodeEnvelope(data!) as bool),
    );
    return reply.future;
  }

  setUp(() {
    playback = null;
    updates = [];
    requestedSeeks = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'setLyrics');
      updates.add(call.arguments as Map<Object?, Object?>?);
      return null;
    });
    widget = MusicLyricsWidget(
      readPlayback: () => playback,
      seek: (position, isCurrent) {
        requestedSeeks.add(position);
        canExecuteSeek = isCurrent;
        return true;
      },
      updates: const [],
    );
  });

  tearDown(() async {
    await widget.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('shows a bounded window and seeks using the adjusted cue times', () {
    const cues = [
      (start: Duration.zero, text: 'Opening'),
      (start: Duration(seconds: 1), text: 'First line'),
      (start: Duration(seconds: 2), text: 'Second line'),
      (start: Duration(seconds: 3), text: 'Third line'),
      (start: Duration(seconds: 4), text: 'Last line'),
    ];
    final rows = musicLyricsWidgetRows(
      cues,
      anchor: 2,
      active: true,
      delay: const Duration(milliseconds: 500),
      seekLimit: const Duration(milliseconds: 2600),
    );
    expect(rows, [
      (positionMs: 1500, text: 'First line', active: false),
      (positionMs: 2500, text: 'Second line', active: true),
    ]);
    final beforeFirstCue = musicLyricsWidgetRows(
      cues,
      anchor: -1,
      active: false,
      delay: const Duration(milliseconds: -500),
      seekLimit: const Duration(seconds: 3),
    );
    expect(
        beforeFirstCue.first, (positionMs: 0, text: 'Opening', active: false));
    expect(beforeFirstCue, hasLength(3));
  });

  test('uses the shared cue anchor without highlighting a silent break', () {
    const lyrics = MusicLyrics.synced(
      [
        (start: Duration(milliseconds: 150), text: 'Opening'),
        (start: Duration(milliseconds: 800), text: 'Next line'),
      ],
      breakStarts: [Duration(milliseconds: 400)],
    );
    const delay = Duration(milliseconds: 25);
    final beforeBreak =
        currentMusicCueAt(lyrics, const Duration(milliseconds: 424), delay);
    final inBreak =
        currentMusicCueAt(lyrics, const Duration(milliseconds: 425), delay)!;
    expect(beforeBreak, (index: 0, text: 'Opening'));
    expect(inBreak, (index: 0, text: null));
    expect(
      musicLyricsWidgetRows(
        lyrics.cues,
        anchor: inBreak.index,
        active: inBreak.text != null,
        delay: delay,
        seekLimit: const Duration(seconds: 1),
      ),
      [
        (positionMs: 175, text: 'Opening', active: false),
        (positionMs: 825, text: 'Next line', active: false),
      ],
    );
  });

  test('an overlapping subtitle resumes until its exclusive end', () {
    const lyrics = MusicLyrics.synced([
      (start: Duration(seconds: 1), text: 'Longer part'),
      (start: Duration(seconds: 2), text: 'Shorter part'),
    ], metadataByCue: {
      0: MusicLyricCueMetadata(end: Duration(seconds: 5)),
      1: MusicLyricCueMetadata(end: Duration(seconds: 3)),
    });
    MusicCurrentCue? at(int second) =>
        currentMusicCueAt(lyrics, Duration(seconds: second), Duration.zero);
    expect(at(2), (index: 1, text: 'Shorter part'));
    expect(at(3), (index: 0, text: 'Longer part'));
    expect(at(5), (index: 1, text: null));
  });

  test('updates only on cue changes and seeks the line originally displayed',
      () async {
    playback = song();
    widget.refresh();
    playback = song(rows: [first]);
    widget.refresh();
    final original = updates.single!;
    final token = original['token'];
    expect(original['cues'], [
      {'positionMs': 1000, 'text': 'First line', 'active': true},
    ]);

    playback = song(rows: [second]);
    widget.refresh();
    expect(updates, hasLength(2));
    expect(updates.last!['token'], token);
    expect(await tap(token, 1000), isTrue);
    expect(await tap(token, 2500), isTrue);
    expect(await tap(token, 1001), isFalse);
    expect(await tap(token, '1000'), isFalse);
    expect(requestedSeeks, [
      const Duration(seconds: 1),
      const Duration(milliseconds: 2500),
    ]);
  });

  test('rejects a delayed tap and queued seek after the occurrence changes',
      () async {
    playback = song();
    widget.refresh();
    final token = updates.last!['token'];
    expect(await tap(token, 1000), isTrue);
    expect(canExecuteSeek(), isTrue);

    playback = song(occurrence: 'queue-two');
    expect(canExecuteSeek(), isFalse);
    expect(await tap(token, 1000), isFalse);
    widget.refresh();
    expect(updates.last!['token'], isNot(token));
    expect(await tap(token, 1000), isFalse);
    expect(await tap(updates.last!['token'], 1000), isTrue);
  });

  test('withdraws the snapshot during a profile transition', () async {
    playback = song();
    widget.refresh();
    final token = updates.last!['token'];
    expect(await tap(token, 1000), isTrue);
    playback = null;
    expect(canExecuteSeek(), isFalse);
    expect(await tap(token, 1000), isFalse);
    widget.refresh();
    expect(updates.last, isNull);

    playback = song(profile: 'profile-two');
    widget.refresh();
    expect(updates.last!['token'], isNot(token));
    expect(await tap(token, 1000), isFalse);
  });

  test('invalidates taps and queued seeks when the lyric timing is edited',
      () async {
    playback = song();
    widget.refresh();
    final token = updates.last!['token'];
    expect(await tap(token, 1000), isTrue);

    playback = song(timeline: 2, rows: const [second]);
    expect(canExecuteSeek(), isFalse);
    expect(await tap(token, 1000), isFalse);
    widget.refresh();
    expect(updates.last!['token'], isNot(token));
    expect(await tap(updates.last!['token'], 1000), isFalse);
    expect(await tap(updates.last!['token'], 2500), isTrue);
  });
}
