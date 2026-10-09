import 'package:flutter_test/flutter_test.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';

import '../../test_app_cubit.dart';
import '../../test_settings_cubit.dart';

Future<void> main() async {
  late SettingsCubit settingsCubit;
  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    var appCubit = TestAppCubit(AppState(0, null, HomeLayout()));
    await appCubit.initState();
    settingsCubit = TestSettingsCubit(SettingsState.init(), appCubit);
  });
  tearDown(() async => await db.close());

  test('sponsor skipping and dislike counts are on without saved settings', () {
    expect(settingsCubit.state.useReturnYoutubeDislike, isTrue);
    final enabled = SponsorSegmentType.values.where((type) => type
        .isEnabled(settingsCubit.state.settings[type.settingsName()]?.value));
    expect(enabled, [SponsorSegmentType.sponsor]);
  });

  test('saved choices override defaults after settings reload', () async {
    await settingsCubit.setUseReturnYoutubeDislike(false);
    for (final type in SponsorSegmentType.values) {
      await settingsCubit
          .saveSetting(SettingsValue(type.settingsName(), 'false'));
    }
    var restored = SettingsState.init();
    expect(restored.useReturnYoutubeDislike, isFalse);
    for (final type in SponsorSegmentType.values) {
      expect(type.isEnabled(restored.settings[type.settingsName()]?.value),
          isFalse);
    }

    await settingsCubit.setUseReturnYoutubeDislike(true);
    await settingsCubit.saveSetting(
        SettingsValue(SponsorSegmentType.intro.settingsName(), 'true'));
    restored = SettingsState.init();
    expect(restored.useReturnYoutubeDislike, isTrue);
    expect(
        SponsorSegmentType.intro.isEnabled(
            restored.settings[SponsorSegmentType.intro.settingsName()]?.value),
        isTrue);
  });

  test('setting and reading settings', () async {
    // testing boolean setting
    await settingsCubit.setUseSearchHistory(true);
    expect(settingsCubit.state.useSearchHistory, true);

    // testing numbers
    await settingsCubit.setSubtitleSize(10);
    expect(settingsCubit.state.subtitleSize, 10);

    //testing strings
    await settingsCubit.setLastSubtitle("en_US");
    expect(settingsCubit.state.lastSubtitles, "en_US");

    // testing skip steps
    await settingsCubit.setSkipStep(skipSteps.first);
    expect(settingsCubit.state.skipStep, skipSteps.first);

    for (int i = 1; i < skipSteps.length; i++) {
      await settingsCubit.changeSkipStep(increase: true);
      expect(settingsCubit.state.skipStep, skipSteps[i]);
    }

    await settingsCubit.changeSkipStep(increase: true);
    // should remain to the max
    expect(settingsCubit.state.skipStep, skipSteps.last);

    await settingsCubit.setSkipStep(skipSteps.last);
    expect(settingsCubit.state.skipStep, skipSteps.last);
    for (int i = skipSteps.length - 2; i > 0; i--) {
      await settingsCubit.changeSkipStep(increase: false);
      expect(settingsCubit.state.skipStep, skipSteps[i]);
    }
  });

  test('Generic set settings method', () async {
    var setting = db.getSettings('test');
    expect(setting, null);

    SettingsValue s = SettingsValue('test', 'yo');
    await settingsCubit.saveSetting(s);
    expect(db.getSettings('test')?.value, 'yo');
  });
}
