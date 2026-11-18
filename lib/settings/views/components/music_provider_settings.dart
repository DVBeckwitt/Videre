import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/music_download_format.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../music/services/music_community_cover_preferences.dart';
import '../../../music/services/music_lyrics_preferences.dart';
import '../../../utils.dart' show selectKeys;

class MusicProviderSettings extends StatelessWidget {
  const MusicProviderSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      _ProviderSwitch(
        tileKey: const ValueKey('music-lrclib-setting'),
        icon: Icons.lyrics_outlined,
        title: locals.musicLrclibSetting,
        help: locals.musicLrclibSettingHelp,
        revision: lrclibPreferenceRevision,
        read: isLrclibEnabled,
        write: setLrclibEnabled,
      ),
      _ProviderSwitch(
        tileKey: const ValueKey('music-community-cover-setting'),
        icon: Icons.album_outlined,
        title: locals.musicCommunityCoverSetting,
        help: locals.musicCommunityCoverSettingHelp,
        revision: communityCoverArtPreferenceRevision,
        read: isCommunityCoverArtEnabled,
        write: setCommunityCoverArtEnabled,
      ),
      Semantics(container: true, child: const _MusicDownloadFormatSetting()),
    ]);
  }
}

class _MusicDownloadFormatSetting extends StatefulWidget {
  const _MusicDownloadFormatSetting();

  @override
  State<_MusicDownloadFormatSetting> createState() =>
      _MusicDownloadFormatSettingState();
}

class _MusicDownloadFormatSettingState
    extends State<_MusicDownloadFormatSetting> {
  Future<void> _selectFormat() async {
    final app = context.read<AppCubit>();
    final database = db;
    final profile = database.profileId;
    final session = app.state.sessionRevision;
    bool isCurrent() =>
        mounted &&
        !app.isClosed &&
        identical(db, database) &&
        db.profileId == profile &&
        app.state.profileId == profile &&
        app.state.sessionRevision == session &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired;
    if (!isCurrent()) return;
    final current = MusicDownloadFormat.forDatabase(database);
    final locals = AppLocalizations.of(context)!;
    final format = await showDialog<MusicDownloadFormat>(
      context: context,
      builder: (context) => Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent()
        },
        child: SimpleDialog(
          title: Text(locals.musicDownloadFormatSetting),
          children: [
            for (final format in MusicDownloadFormat.values)
              ListTile(
                key: ValueKey('music-download-format-${format.name}'),
                autofocus: format == current,
                selected: format == current,
                title: Text(format.label),
                trailing: format == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, format),
              ),
            Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(locals.cancel))),
          ],
        ),
      ),
    );
    if (format == null || format == current || !isCurrent()) return;
    try {
      await format.save(database);
      if (isCurrent()) setState(() {});
    } catch (_) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(locals.error)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>().state;
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent()
      },
      child: ListTile(
        key: const ValueKey('music-download-format-setting'),
        leading: const Icon(Icons.audio_file_outlined),
        title: Text(AppLocalizations.of(context)!.musicDownloadFormatSetting),
        subtitle: Text(MusicDownloadFormat.forDatabase(db).label),
        onTap: db.profileId == app.profileId &&
                !app.globalLoading &&
                !app.sessionRecoveryRequired
            ? _selectFormat
            : null,
      ),
    );
  }
}

class _ProviderSwitch extends StatelessWidget {
  final Key tileKey;
  final IconData icon;
  final String title, help;
  final ValueListenable<int> revision;
  final bool Function() read;
  final Future<void> Function(bool, {String? expectedProfileId}) write;

  const _ProviderSwitch({
    required this.tileKey,
    required this.icon,
    required this.title,
    required this.help,
    required this.revision,
    required this.read,
    required this.write,
  });

  @override
  Widget build(BuildContext context) {
    final profile = context.select((AppCubit app) => app.state.profileId);
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (context, _, child) {
        final active = db.profileId == profile;
        return Shortcuts(
          shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent(),
          },
          child: SwitchListTile(
            key: tileKey,
            secondary: Icon(icon),
            title: Text(title),
            subtitle: Text(help),
            value: active && read(),
            onChanged: active
                ? (value) async {
                    try {
                      await write(value, expectedProfileId: profile);
                    } catch (_) {
                      if (context.mounted && db.profileId == profile) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content:
                                Text(AppLocalizations.of(context)!.error)));
                      }
                    }
                  }
                : null,
          ),
        );
      },
    );
  }
}
