import 'dart:async';
import 'dart:convert';

import 'package:clipious/podcasts/services/podcast_progress_store.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_memory.dart';

class _ControlledDatabase implements IDbClient {
  final values = <String, SettingsValue>{};
  final writeStarted = Completer<void>();
  Completer<void>? hold;
  bool failNext = false;

  @override
  String get profileId => 'owner';

  @override
  IDbClient forProfile(String id) {
    if (id != profileId) throw StateError('Unknown profile');
    return this;
  }

  @override
  SettingsValue? getSettings(String name) => values[name];

  @override
  Future<void> saveSetting(SettingsValue setting) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await hold?.future;
    if (failNext) {
      failNext = false;
      throw StateError('Write failed');
    }
    values[setting.name] = setting;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

PodcastProgress _position(int seconds,
        {int duration = 300, bool completed = false}) =>
    PodcastProgress(
        position: Duration(seconds: seconds),
        duration: Duration(seconds: duration),
        completed: completed);

void main() {
  late SembastSqfDb database;
  late PodcastProgressStore progress;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    progress = PodcastProgressStore.forProfile(database, database.profileId);
  });
  tearDown(() async => database.close());

  test('positions survive closing and reopening the database', () async {
    final factory = newDatabaseFactoryMemory();
    var connection = await factory.openDatabase('podcast-progress');
    var owner = SembastSqfDb(connection);
    await owner.getProfiles();
    await PodcastProgressStore.forProfile(owner, owner.profileId)
        .save('episode', _position(123));
    await owner.close();
    connection = await factory.openDatabase('podcast-progress');
    owner = SembastSqfDb(connection);
    await owner.getProfiles();
    final restored =
        await PodcastProgressStore.forProfile(owner, owner.profileId)
            .read('episode');
    expect(restored!.position, const Duration(seconds: 123));
    expect(restored.duration, const Duration(seconds: 300));
    expect(restored.completed, isFalse);
    await owner.close();
  });

  test('captured writes remain in the original profile after selection changes',
      () async {
    final original = database.profileId;
    final next = await database.createProfile('Second listener');
    final writing = progress.save('same-episode', _position(42));
    await database.useProfile(next.id);
    await writing;
    final other = PodcastProgressStore.forProfile(database, next.id);
    expect((await progress.read('same-episode'))!.position,
        const Duration(seconds: 42));
    expect(await other.read('same-episode'), isNull);
    await other.save('same-episode', _position(7));
    expect(
        (await PodcastProgressStore.forProfile(database, original)
                .read('same-episode'))!
            .position,
        const Duration(seconds: 42));
    expect((await other.read('same-episode'))!.position,
        const Duration(seconds: 7));
  });

  test('a deleted profile cannot receive a delayed checkpoint or be recreated',
      () async {
    final original = database.profileId;
    final next = await database.createProfile('Second listener');
    await database.useProfile(next.id);
    await database.deleteProfile(original);
    await expectLater(
        progress.save('episode', _position(12)), throwsStateError);
    expect((await database.getProfiles()).map((value) => value.id), [next.id]);
    expect(database.getSettings(podcastProgressSettingName), isNull);
  });

  test('concurrent wrappers keep all episodes and the latest explicit rewind',
      () async {
    final other = PodcastProgressStore.forProfile(database, database.profileId);
    await Future.wait([
      progress.save('episode-a', _position(120)),
      other.save('episode-b', _position(64)),
      other.save('episode-a', _position(15)),
    ]);
    expect((await progress.read('episode-a'))!.position,
        const Duration(seconds: 15));
    expect((await progress.read('episode-b'))!.position,
        const Duration(seconds: 64));
  });

  test('read waits for a predecessor checkpoint and a failed write can recover',
      () async {
    final owner = _ControlledDatabase();
    final first = PodcastProgressStore.forProfile(owner, owner.profileId);
    final second = PodcastProgressStore.forProfile(owner, owner.profileId);
    owner.hold = Completer<void>();
    final writing = first.save('episode', _position(42));
    await owner.writeStarted.future;
    var finished = false;
    final reading = second.read('episode').then((value) {
      finished = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    owner.hold!.complete();
    await writing;
    expect((await reading)!.position, const Duration(seconds: 42));
    owner.hold = null;
    owner.failNext = true;
    await expectLater(first.save('episode', _position(55)), throwsStateError);
    expect(
        (await second.read('episode'))!.position, const Duration(seconds: 42));
    await second.save('episode', _position(10));
    expect(
        (await first.read('episode'))!.position, const Duration(seconds: 10));
  });

  test(
      'completion starts at zero while unknown or stale durations retain position',
      () async {
    await progress.save('finished', _position(300, completed: true));
    final finished = (await progress.read('finished'))!;
    expect(finished.completed, isTrue);
    expect(finished.position, Duration.zero);
    await progress.save('unknown', _position(120, duration: 0));
    await progress.save('changed', _position(120, duration: 60));
    expect((await progress.read('unknown'))!.position,
        const Duration(seconds: 120));
    expect((await progress.read('changed'))!.position,
        const Duration(seconds: 120));
    await progress.save('finished', _position(20));
    expect((await progress.read('finished'))!.completed, isFalse);
    expect((await progress.read('finished'))!.position,
        const Duration(seconds: 20));
  });

  test('malformed rows are ignored and rewrites retain only IDs and timings',
      () async {
    final valid = {
      'positionMs': 12000,
      'durationMs': 30000,
      'completed': false
    };
    await database.saveSetting(SettingsValue(
        podcastProgressSettingName,
        jsonEncode({
          'version': 1,
          'entries': {
            'good': {...valid, 'url': 'https://publisher.example/private'},
            'negative': {...valid, 'positionMs': -1},
            'huge': {...valid, 'durationMs': Duration(days: 8).inMilliseconds},
            'text': {...valid, 'positionMs': '12000'},
            'bad-flag': {...valid, 'completed': 'false'},
            'https://publisher.example/feed': valid,
          }
        })));
    expect(
        (await progress.read('good'))!.position, const Duration(seconds: 12));
    for (final id in ['negative', 'huge', 'text', 'bad-flag']) {
      expect(await progress.read(id), isNull);
    }
    await progress.save('fresh', _position(4));
    final stored = database.getSettings(podcastProgressSettingName)!.value;
    expect(stored, isNot(contains('publisher')));
    final data = jsonDecode(stored) as Map<String, dynamic>;
    expect((data['entries'] as Map).keys, ['good', 'fresh']);
    expect(((data['entries'] as Map)['good'] as Map).keys,
        ['positionMs', 'durationMs', 'completed']);
  });

  test(
      'invalid input is rejected and damaged or oversized storage is repairable',
      () async {
    for (final id in ['', 'https://host/audio', 'x' * 129, 'episode\n']) {
      await expectLater(progress.save(id, _position(1)), throwsArgumentError);
    }
    await expectLater(
        progress.save('episode', _position(-1)), throwsArgumentError);
    await expectLater(progress.save('episode', _position(1, duration: -1)),
        throwsArgumentError);
    await expectLater(
        progress.save('episode', _position(8 * 86400)), throwsArgumentError);
    for (final value in [
      '{',
      '{"version":2,"entries":{}}',
      'x' * (podcastProgressMaximumBytes + 1)
    ]) {
      await database
          .saveSetting(SettingsValue(podcastProgressSettingName, value));
      expect(await progress.read('episode'), isNull);
      await progress.save('episode', _position(3));
      expect((await progress.read('episode'))!.position,
          const Duration(seconds: 3));
    }
  });

  test(
      'bounded retention keeps recently updated entries and removes the oldest',
      () async {
    final entries = <String, Object>{
      for (var index = 0; index < podcastProgressMaximumEntries; index++)
        'episode-$index': {
          'positionMs': 1000,
          'durationMs': 2000,
          'completed': false
        },
    };
    await database.saveSetting(SettingsValue(podcastProgressSettingName,
        jsonEncode({'version': 1, 'entries': entries})));
    await progress.save('episode-0', _position(2));
    await progress.save('newest', _position(3));
    expect(await progress.read('episode-1'), isNull);
    expect((await progress.read('episode-0'))!.position,
        const Duration(seconds: 2));
    expect(
        (await progress.read('newest'))!.position, const Duration(seconds: 3));
    final data =
        jsonDecode(database.getSettings(podcastProgressSettingName)!.value)
            as Map;
    expect((data['entries'] as Map).length, podcastProgressMaximumEntries);
  });
}
