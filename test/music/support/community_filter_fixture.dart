import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:flutter_test/flutter_test.dart';

const musicListedUploader = 'UC0000000000000000000000';
const youtubeWarnedUploader = 'UC1111111111111111111111';

Future<void> installCommunityMusicFilters() async {
  final previous = communityFilters;
  addTearDown(() => communityFilters = previous);
  await db.saveSetting(
      SettingsValue(CommunityRule.music.setting, CommunityAction.hide.name));
  await db.saveSetting(SettingsValue(
      CommunityRule.youtubeWarn.setting, CommunityAction.label.name));
  communityFilters =
      CommunityFilters(database: () => db, repository: _FixtureStore());
  await communityFilters.reloadForProfile();
}

class _FixtureStore implements CommunityListStore {
  @override
  Future<CommunitySnapshot?> load(CommunityList list) async => _snapshot(list);

  @override
  Future<CommunitySnapshot> refresh(CommunityList list,
          {required bool Function() isCurrent}) async =>
      _snapshot(list);

  CommunitySnapshot _snapshot(CommunityList source) => CommunitySnapshot(
        version: 1,
        generatedAt: DateTime.now().toUtc(),
        blockIds:
            source == CommunityList.aimusic ? {musicListedUploader} : const {},
        blockHandles: const {},
        warnIds: source == CommunityList.aislist
            ? {youtubeWarnedUploader}
            : const {},
        warnHandles: const {},
      );
}
