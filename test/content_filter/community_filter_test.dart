import 'dart:async';

import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/backup.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _block = 'UC1234567890123456789012';
const _warn = 'UCabcdefghijklmnopqrstuv';
const _music = 'UCABCDEFGHIJKLMNOPQRSTUV';
final _now = DateTime.utc(2026, 11, 16);

class _Store implements CommunityListStore {
  final loads = <CommunityList>[];
  final refreshes = <CommunityList>[];
  Future<CommunitySnapshot> Function(CommunityList, bool Function())? update;

  @override
  Future<CommunitySnapshot?> load(CommunityList list) async {
    loads.add(list);
    return null;
  }

  @override
  Future<CommunitySnapshot> refresh(CommunityList list,
      {required bool Function() isCurrent}) async {
    refreshes.add(list);
    if (update case final custom?) return custom(list, isCurrent);
    return _snapshot(list);
  }
}

CommunitySnapshot _snapshot(CommunityList list) => CommunitySnapshot(
      version: 1,
      generatedAt: _now,
      checkedAt: _now,
      blockIds: list == CommunityList.aislist ? {_block} : {_music, _block},
      warnIds: list == CommunityList.aislist ? {_warn} : {},
      blockHandles: list == CommunityList.aislist ? {'café'} : {},
      warnHandles: {},
    );

void main() {
  late SembastSqfDb database;
  late CommunityFilters filters;
  late _Store store;
  late DateTime clock;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    store = _Store();
    clock = _now;
    filters = CommunityFilters(
      database: () => database,
      repository: store,
      now: () => clock,
    );
    await filters.reloadForProfile();
  });

  tearDown(() => database.close());

  test('disabled profiles neither read nor request the lists', () async {
    expect(filters.match(authorId: _block, music: true), isEmpty);
    await filters.refresh(CommunityList.aislist);
    await filters.refreshIfStale();
    expect(store.loads, isEmpty);
    expect(store.refreshes, isEmpty);
  });

  test('first instance setup offers hide and label before enabling AiSList',
      () async {
    expect(filters.needsYoutubeSetup, isTrue);
    final block = filters.youtubeSetupAction(CommunityRule.youtubeBlock);
    final warning = filters.youtubeSetupAction(CommunityRule.youtubeWarn);
    expect(block, CommunityAction.hide);
    expect(warning, CommunityAction.label);
    expect(store.loads, isEmpty);
    expect(store.refreshes, isEmpty);

    await filters.completeYoutubeSetup(block: block, warning: warning);
    await filters.refreshIfStale();
    expect(filters.needsYoutubeSetup, isFalse);
    expect(store.refreshes, [CommunityList.aislist]);
    expect(filters.match(authorId: _block).single.action, CommunityAction.hide);
    expect(filters.match(authorId: _warn).single.action, CommunityAction.label);
    expect(filters.action(CommunityRule.music), CommunityAction.off);
  });

  test('both Off selections persist and setup cannot overwrite them', () async {
    await filters.completeYoutubeSetup(
      block: CommunityAction.off,
      warning: CommunityAction.off,
    );
    await filters.reloadForProfile();
    expect(filters.needsYoutubeSetup, isFalse);
    expect(filters.youtubeSetupAction(CommunityRule.youtubeBlock),
        CommunityAction.off);
    expect(filters.youtubeSetupAction(CommunityRule.youtubeWarn),
        CommunityAction.off);
    await filters.completeYoutubeSetup(
      block: CommunityAction.hide,
      warning: CommunityAction.label,
    );
    expect(filters.enabled(CommunityList.aislist), isFalse);
    expect(store.loads, isEmpty);
    expect(store.refreshes, isEmpty);
  });

  test('setup preselects existing choices and completion is profile-specific',
      () async {
    await database.saveSetting(SettingsValue(
        CommunityRule.youtubeBlock.setting, CommunityAction.off.name));
    await filters.reloadForProfile();
    expect(filters.youtubeSetupAction(CommunityRule.youtubeBlock),
        CommunityAction.off);
    expect(filters.youtubeSetupAction(CommunityRule.youtubeWarn),
        CommunityAction.label);
    await filters.completeYoutubeSetup(
      block: CommunityAction.off,
      warning: CommunityAction.off,
    );
    final second = await database.createProfile('Second');
    await database.useProfile(second.id);
    await filters.reloadForProfile();
    expect(filters.needsYoutubeSetup, isTrue);
    expect(filters.youtubeSetupAction(CommunityRule.youtubeBlock),
        CommunityAction.hide);
  });

  test('stale AiSList updates automatically with no settings changes',
      () async {
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.hide);
    // This is the same check used when the app resumes.
    await filters.refreshIfStale();
    expect(filters.match(authorId: _block).single.action, CommunityAction.hide);

    store.update = (list, _) async => CommunitySnapshot(
          version: 2,
          generatedAt: clock,
          checkedAt: clock,
          blockIds: {_warn},
          blockHandles: {},
          warnIds: {},
          warnHandles: {},
        );
    clock = _now.add(const Duration(hours: 23));
    await filters.refreshIfStale();
    expect(store.refreshes, [CommunityList.aislist]);
    expect(filters.status(CommunityList.aislist).version, 1);

    clock = _now.add(const Duration(hours: 26));
    await filters.refreshIfStale();
    expect(store.refreshes, [CommunityList.aislist, CommunityList.aislist]);
    expect(filters.status(CommunityList.aislist).version, 2);
    expect(filters.match(authorId: _block), isEmpty);
    expect(filters.match(authorId: _warn).single.action, CommunityAction.hide);
  });

  test('correcting the device clock allows an automatic refresh', () async {
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.hide);
    await filters.refreshIfStale();
    expect(store.refreshes, [CommunityList.aislist]);

    clock = _now.subtract(const Duration(hours: 2));
    await filters.refreshIfStale();
    expect(store.refreshes, [CommunityList.aislist, CommunityList.aislist]);

    await filters.refreshIfStale();
    expect(store.refreshes, [CommunityList.aislist, CommunityList.aislist]);
  });

  test(
      'independent actions cover both AiSList tiers and only Music gets aimusic',
      () async {
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.hide);
    await filters.setAction(CommunityRule.youtubeWarn, CommunityAction.label);
    await filters.setAction(CommunityRule.music, CommunityAction.label);
    await filters.refreshIfStale();
    expect(store.refreshes, unorderedEquals(CommunityList.values));
    expect(filters.match(authorId: _block).single.action, CommunityAction.hide);
    expect(filters.match(authorId: _warn).single.action, CommunityAction.label);
    expect(filters.match(authorId: _warn).single.warning, isTrue);
    expect(filters.match(authorId: _music), isEmpty);
    expect(filters.match(authorId: _music, music: true).single.source,
        CommunityList.aimusic);
    expect(filters.match(authorId: _block, music: true).map((m) => m.source),
        CommunityList.values);
    await filters.setAction(CommunityRule.youtubeWarn, CommunityAction.hide);
    expect(filters.match(authorId: _warn).single.action, CommunityAction.hide);
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.off);
    expect(filters.match(authorId: _block), isEmpty);
    expect(filters.match(authorId: _block, music: true).single.source,
        CommunityList.aimusic);
  });

  test(
      'normalizes exact handles and learns a channel ID from received metadata',
      () async {
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.label);
    await filters.refreshIfStale();
    const other = 'UC0000000000000000000000';
    expect(filters.match(authorUrl: '/@CaFe%CC%81-extra'), isEmpty);
    expect(filters.match(authorUrl: 'https://example.com/@Caf%C3%A9'), isEmpty);
    expect(filters.match(authorId: other), isEmpty);
    expect(
        filters
            .match(authorId: other, authorUrl: '/@CAFE%CC%81')
            .single
            .identity,
        other);
    expect(filters.match(authorId: other).single.identity, other);
    expect(filters.match(authorId: _block.toLowerCase()), isEmpty);
  });

  test('labels matches by canonical author URL when the ID is missing',
      () async {
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.label);
    await filters.refreshIfStale();

    final relative = filters.match(authorUrl: '/channel/$_block').single;
    expect(relative.action, CommunityAction.label);
    expect(relative.identity, _block);
    expect(
      filters
          .match(
              authorId: '',
              authorUrl: 'https://wWw.YouTube.Com/channel/$_block')
          .single
          .identity,
      _block,
    );
    expect(
      filters.match(authorId: _warn, authorUrl: '/channel/$_block'),
      isEmpty,
      reason: 'a valid explicit channel ID takes priority',
    );

    for (final url in [
      _block,
      'https://example.com/channel/$_block',
      'https://youtube.com.example.com/channel/$_block',
      'https://youtube.com@example.com/channel/$_block',
      'https://example.com@youtube.com/channel/$_block',
      'http://youtube.com/channel/$_block',
      '//youtube.com/channel/$_block',
      '/unrelated/../channel/$_block',
      '/CHANNEL/$_block',
      'https://wWw.YouTube.Com/CHANNEL/$_block',
      '/channel/$_block/anything',
      '/channel/$_block?next=/channel/$_warn',
      '/channel/$_block\n',
    ]) {
      expect(filters.match(authorUrl: url), isEmpty, reason: url);
    }

    await filters.allow(relative);
    expect(filters.match(authorId: _block), isEmpty);
    expect(filters.match(authorUrl: '/channel/$_block'), isEmpty);
  });

  test('allow only changes this source and profile and preserves manual data',
      () async {
    final originalId = database.profileId;
    await database.saveFilter(VideoFilter(value: 'manual'));
    await database.upsertHistoryVideo(
        HistoryVideoCache('abcdefghijk', 'Saved', 'Author', ''));
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.hide);
    await filters.setAction(CommunityRule.music, CommunityAction.hide);
    await filters.refreshIfStale();
    await filters.allow(filters.match(authorId: _block).single);
    expect(filters.match(authorId: _block), isEmpty);
    expect(filters.match(authorId: _block, music: true).single.source,
        CommunityList.aimusic);
    expect(database.getAllFilters().single.value, 'manual');
    expect(database.getLocalHistory().single.videoId, 'abcdefghijk');
    final second = await database.createProfile('Another person');
    await database.useProfile(second.id);
    await filters.reloadForProfile();
    expect(filters.action(CommunityRule.youtubeBlock), CommunityAction.off);
    expect(filters.exceptions(CommunityList.aislist), isEmpty);
    await database.useProfile(originalId);
    await filters.reloadForProfile();
    expect(filters.exceptions(CommunityList.aislist), {_block});
    await filters.removeException(CommunityList.aislist, _block);
    expect(filters.match(authorId: _block).single.action, CommunityAction.hide);
  });

  test(
      'retains the valid snapshot through refresh failure and cancels on disable',
      () async {
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.hide);
    await filters.refreshIfStale();
    store.update = (list, current) => Future.error(const FormatException());
    await filters.refresh(CommunityList.aislist);
    expect(filters.status(CommunityList.aislist).failed, isTrue);
    expect(filters.match(authorId: _block), hasLength(1));
    final started = Completer<bool Function()>();
    final result = Completer<CommunitySnapshot>();
    store.update = (list, current) {
      started.complete(current);
      return result.future;
    };
    final refreshing = filters.refresh(CommunityList.aislist);
    final current = await started.future;
    await filters.setAction(CommunityRule.youtubeBlock, CommunityAction.off);
    expect(current(), isFalse);
    result.complete(_snapshot(CommunityList.aislist));
    await refreshing;
    expect(filters.match(authorId: _block, music: true), isEmpty);
    expect(filters.status(CommunityList.aislist).refreshing, isFalse);
  });

  test('portable backup validates rules and exact exception identities', () {
    expect(
        UserBackup.validSetting(
            SettingsValue(CommunityRule.music.setting, 'hide')),
        isTrue);
    expect(
        UserBackup.validSetting(
            SettingsValue(CommunityRule.music.setting, 'true')),
        isFalse);
    final key = communityExceptionsSetting(CommunityList.aislist);
    expect(UserBackup.validSetting(SettingsValue(key, '["$_block","@café"]')),
        isTrue);
    expect(UserBackup.validSetting(SettingsValue(key, '["some channel name"]')),
        isFalse);
  });
}
