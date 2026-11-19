import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import '../../states/download_manager.dart';

Future<void> showDownloadFolder(BuildContext context) => showDialog<void>(
    animationStyle: AppMotion.dialogStyle(context),
    context: context,
    builder: (_) => BlocProvider.value(
        value: context.read<DownloadManagerCubit>(),
        child: const _DownloadFolderDialog()));

class _DownloadFolderDialog extends StatefulWidget {
  const _DownloadFolderDialog();

  @override
  State<_DownloadFolderDialog> createState() => _DownloadFolderDialogState();
}

enum _Destination { standard, private, custom }

class _DownloadFolderDialogState extends State<_DownloadFolderDialog> {
  bool _busy = false;
  bool _editingAudio = false;
  String? _error;

  Future<void> _change(_Destination destination,
      {required bool audioOnly}) async {
    if (_busy) return;
    final manager = context.read<DownloadManagerCubit>();
    final locals = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _editingAudio = audioOnly;
      _error = null;
    });
    try {
      switch (destination) {
        case _Destination.standard:
          await manager.useDefaultFolder(audioOnly: audioOnly);
        case _Destination.private:
          await manager.usePrivateFolder(audioOnly: audioOnly);
        case _Destination.custom:
          await manager.chooseFolder(audioOnly: audioOnly);
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _error = error.code == 'PICKER_UNAVAILABLE'
            ? locals.downloadFolderPickerUnavailable
            : locals.downloadFolderError);
      }
    } on MissingPluginException {
      if (mounted) {
        setState(() => _error = locals.downloadFolderPickerUnavailable);
      }
    } catch (_) {
      if (mounted) setState(() => _error = locals.downloadFolderError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final state = context.watch<DownloadManagerCubit>().state;
    Widget section({required bool audioOnly}) {
      final type = audioOnly ? 'audio' : 'video';
      final heading =
          audioOnly ? locals.downloadFolderAudio : locals.downloadFolderVideo;
      final folderName = audioOnly ? state.audioFolderName : state.folderName;
      final folderUri = audioOnly ? state.audioFolderUri : state.folderUri;
      final selected = folderUri != null
          ? _Destination.custom
          : audioOnly && !state.usePrivateAudioStorage
              ? _Destination.standard
              : _Destination.private;
      Widget option(_Destination value, String title, String subtitle) {
        final active = selected == value;
        return Semantics(
          key: ValueKey('download-folder-$type-${value.name}'),
          inMutuallyExclusiveGroup: true,
          checked: active,
          label: heading,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            autofocus: !audioOnly && active,
            leading: Icon(active
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked),
            title: Text(title),
            subtitle: Text(subtitle),
            onTap: _busy ? null : () => _change(value, audioOnly: audioOnly),
          ),
        );
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
            header: true,
            child:
                Text(heading, style: Theme.of(context).textTheme.titleMedium)),
        if (audioOnly)
          option(_Destination.standard, locals.downloadFolderDefault,
              locals.downloadFolderDefaultDetails),
        option(_Destination.private, locals.downloadFolderPrivate,
            locals.downloadFolderPrivateDetails),
        option(_Destination.custom, locals.downloadFolderChoose,
            folderName ?? locals.downloadFolderCustomDetails),
        if (_editingAudio == audioOnly && _busy)
          const MotionLoadingIndicator(child: LinearProgressIndicator()),
        if (_editingAudio == audioOnly && _error != null)
          Semantics(
              liveRegion: true,
              child: Text(_error!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
      ]);
    }

    return PopScope(
      canPop: !_busy,
      child: Shortcuts(
          shortcuts: {
            for (final key in selectKeys)
              SingleActivator(key): const ActivateIntent()
          },
          child: AlertDialog(
            title: Text(locals.downloadFolder),
            content: SingleChildScrollView(
                child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                section(audioOnly: false),
                const Divider(height: 24),
                section(audioOnly: true),
                const SizedBox(height: 12),
                Text(locals.downloadFolderExistingFiles),
              ],
            )),
            actions: [
              TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: Text(locals.ok)),
            ],
          )),
    );
  }
}
