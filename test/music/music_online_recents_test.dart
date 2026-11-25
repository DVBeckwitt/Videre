import 'dart:async';

import 'package:clipious/music/services/music_online_recents.dart';
import 'package:clipious/search/models/db/search_history_item.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

void main() {
  late SembastSqfDb database;
  late MusicOnlineRecents recents;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    recents = MusicOnlineRecents.forProfile(database, database.profileId);
  });
  tearDown(() async => database.close());

  Future<void> submit(String text) =>
      recents.recordSubmission(text, isCurrent: () => true);

  test('defaults off and keeps bounded exact queries in newest-first order',
      () async {
    expect(recents.enabled, isFalse);
    await submit('Ignored while off');
    expect(recents.queries, isEmpty);
    expect(database.getAllSettings(), isEmpty);

    await recents.setEnabled(true);
    await Future.wait([for (var i = 0; i < 23; i++) submit('Track $i')]);
    await submit('  Café  session 🎶  ');
    await submit('Track 19');
    await submit('x' * 201);
    await submit('   ');
    await submit('https://user:password@example.net/private');
    expect(recents.queries.length, 20);
    expect(
        recents.queries.take(3), ['Track 19', 'Café  session 🎶', 'Track 22']);
    expect(recents.queries.where((item) => item == 'Track 19'), hasLength(1));
    expect(recents.queries, isNot(contains('Track 2')));
    expect(() => recents.queries.clear(), throwsUnsupportedError);

    await recents.remove('Café  session 🎶');
    final reopened = MusicOnlineRecents.forProfile(
        SembastSqfDb(database.db), database.profileId);
    expect(reopened.enabled, isTrue);
    expect(reopened.queries, recents.queries);
    expect(reopened.queries, isNot(contains('Café  session 🎶')));
    expect(database.getSearchHistory(), isEmpty);
  });

  test(
      'editing replaces the saved entry at its position and removes duplicates',
      () async {
    await recents.setEnabled(true);
    await submit('One');
    await submit('Two');
    await submit('Three');
    await recents.rename('Two', '  Café  session 🎶  ');
    expect(recents.queries, ['Three', 'Café  session 🎶', 'One']);
    await recents.rename('One', 'Three');
    expect(recents.queries, ['Café  session 🎶', 'Three']);
    await recents.rename('Three', 'https://example.net/private');
    expect(recents.queries, ['Café  session 🎶', 'Three']);
  });

  test('a clear or disable cannot be undone by a queued submission', () async {
    await recents.setEnabled(true);
    await submit('On disk before clear');
    await Future.wait([
      submit('Pending before clear'),
      recents.clear(),
      submit('Explicitly submitted after clear'),
    ]);
    expect(recents.enabled, isTrue);
    expect(recents.queries, ['Explicitly submitted after clear']);

    await Future.wait([
      submit('Pending before disable'),
      recents.setEnabled(false),
      submit('Submitted with disable queued'),
      recents.setEnabled(true),
    ]);
    expect(recents.enabled, isTrue);
    expect(recents.queries, isEmpty);
    await submit('After new opt-in');
    expect(recents.queries, ['After new opt-in']);

    await recents.setEnabled(false);
    expect(recents.enabled, isFalse);
    expect(recents.queries, isEmpty);
    expect(database.getAllSettings(), isEmpty);
  });

  test('ignores queued writes once their caller is retired', () async {
    await recents.setEnabled(true);
    await submit('Kept search');
    var current = true;
    final stale =
        recents.recordSubmission('Retired search', isCurrent: () => current);
    current = false;
    await stale;
    current = true;
    final staleEdit =
        recents.rename('Kept search', 'Retired edit', isCurrent: () => current);
    current = false;
    await staleEdit;
    await recents.remove('Kept search', isCurrent: () => current);
    await recents.clear(isCurrent: () => current);
    await recents.setEnabled(false, isCurrent: () => current);
    expect(recents.enabled, isTrue);
    expect(recents.queries, ['Kept search']);
  });

  test('accepted clear and disable finish against the original profile',
      () async {
    final other = await database.createProfile('Other listener');
    final otherRecents = MusicOnlineRecents.forProfile(database, other.id);
    await otherRecents.setEnabled(true);
    await otherRecents.recordSubmission('Other entry', isCurrent: () => true);
    await recents.setEnabled(true);
    await submit('First entry');

    var current = true;
    final clear = recents.clear(isCurrent: () => current);
    current = false;
    await clear;
    expect(recents.enabled, isTrue);
    expect(recents.queries, isEmpty);

    await submit('New entry');
    current = true;
    final disable = recents.setEnabled(false, isCurrent: () => current);
    current = false;
    await Future.wait([disable, database.useProfile(other.id)]);
    expect(recents.enabled, isFalse);
    expect(recents.queries, isEmpty);
    expect(otherRecents.queries, ['Other entry']);
  });

  test('profile owners and notifications remain isolated across selection',
      () async {
    final originalId = database.profileId;
    final originalAgain = MusicOnlineRecents.forProfile(database, originalId);
    expect(originalAgain, same(recents));
    final other = await database.createProfile('Other listener');
    final otherRecents = MusicOnlineRecents.forProfile(database, other.id);
    var originalNotifications = 0;
    var otherNotifications = 0;
    recents.addListener(() => originalNotifications++);
    otherRecents.addListener(() => otherNotifications++);

    await recents.setEnabled(true);
    await submit('First listener');
    expect(originalNotifications, 2);
    expect(otherNotifications, 0);

    await database.useProfile(other.id);
    expect(otherRecents.enabled, isFalse);
    expect(otherRecents.queries, isEmpty);
    await otherRecents.setEnabled(true);
    await recents.recordSubmission('Retired profile',
        isCurrent: () => database.profileId == originalId);
    await otherRecents.recordSubmission('Second listener',
        isCurrent: () => database.profileId == other.id);
    expect(recents.queries, ['First listener']);
    expect(otherRecents.queries, ['Second listener']);
    expect(originalNotifications, 2);
    expect(otherNotifications, 2);

    await database.useProfile(originalId);
    expect(MusicOnlineRecents.forProfile(database, database.profileId).queries,
        ['First listener']);
  });

  test('deleting a profile removes recents and retires its late write',
      () async {
    final person = await database.createProfile('Removed listener');
    final removed = MusicOnlineRecents.forProfile(database, person.id);
    await removed.setEnabled(true);
    await removed.recordSubmission('Existing', isCurrent: () => true);
    final entered = Completer<void>();
    final release = Completer<void>();
    final blocker = database.db.transaction((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final deletion = database.deleteProfile(person.id);
    final late = removed.recordSubmission('Too late', isCurrent: () => true);
    await Future<void>.value();
    release.complete();
    await Future.wait([blocker, deletion, late]);

    expect(removed.enabled, isFalse);
    expect(removed.queries, isEmpty);
    expect(
        await stringMapStoreFactory
            .store('profile:${person.id}:settings')
            .count(database.db),
        0);
  });

  test('portable backup neither sends nor replaces local Music recents',
      () async {
    await database.addToSearchHistory(SearchHistoryItem('General text', 0));
    await recents.setEnabled(true);
    await submit('Music-specific text');
    final backup = await database.exportBackup();
    expect(backup.encode(), isNot(contains('General text')));
    expect(backup.encode(), isNot(contains('Music-specific text')));
    expect(backup.encode(), isNot(contains('music-online-recents-v1')));
    expect(database.getSearchHistory(), ['General text']);

    final person = await database.createProfile('Receiving listener');
    final target = database.forProfile(person.id);
    final targetRecents = MusicOnlineRecents.forProfile(database, person.id);
    await target.restoreBackup(backup, replace: true);
    expect(targetRecents.enabled, isFalse);
    expect(targetRecents.queries, isEmpty);
    await targetRecents.setEnabled(true);
    await targetRecents.recordSubmission('Kept locally', isCurrent: () => true);
    await target.restoreBackup(backup, replace: true);
    expect(targetRecents.queries, ['Kept locally']);
    expect(recents.queries, ['Music-specific text']);
  });

  test('a malformed packed value cannot enable recents', () async {
    await database.saveSetting(SettingsValue(
        'music-online-recents-v1', '{"version":1,"queries":[""]}'));
    expect(recents.enabled, isFalse);
    expect(recents.queries, isEmpty);
    await recents.setEnabled(true);
    expect(recents.enabled, isTrue);
    expect(recents.queries, isEmpty);
  });
}
