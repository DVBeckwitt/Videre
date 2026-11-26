import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../components/music_provider_settings.dart';

class MusicSettingsScreen extends StatelessWidget {
  final bool television;
  final String focusedSetting;
  final FocusNode settingFocusNode;

  const MusicSettingsScreen({
    super.key,
    required this.television,
    required this.focusedSetting,
    required this.settingFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final body = SafeArea(
      child: SingleChildScrollView(
        child: MusicProviderSettings(
          television: television,
          focusedSetting: focusedSetting,
          settingFocusNode: settingFocusNode,
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(locals.ytMusicSettings)),
      body: television ? TvOverscan(child: body) : body,
    );
  }
}
