import 'package:clipious/utils/motion.dart';
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
  String? _error;

  Future<void> _change(_Destination destination) async {
    if (_busy) return;
    final manager = context.read<DownloadManagerCubit>();
    final locals = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (destination) {
        case _Destination.standard:
          await manager.useDefaultFolder();
        case _Destination.private:
          await manager.usePrivateFolder();
        case _Destination.custom:
          await manager.chooseFolder();
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
    final selected = state.folderUri != null
        ? _Destination.custom
        : state.usePrivateStorage
            ? _Destination.private
            : _Destination.standard;

    Widget option(_Destination value, String title, String subtitle) {
      final active = selected == value;
      return Semantics(
        inMutuallyExclusiveGroup: true,
        checked: active,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(active
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked),
          title: Text(title),
          subtitle: Text(subtitle),
          onTap: _busy ? null : () => _change(value),
        ),
      );
    }

    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(locals.downloadFolder),
        content: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            option(_Destination.standard, locals.downloadFolderDefault,
                locals.downloadFolderDefaultDetails),
            option(_Destination.private, locals.downloadFolderPrivate,
                locals.downloadFolderPrivateDetails),
            option(_Destination.custom, locals.downloadFolderChoose,
                state.folderName ?? locals.downloadFolderCustomDetails),
            const SizedBox(height: 12),
            Text(locals.downloadFolderExistingFiles),
            if (_busy)
              const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child:
                      MotionLoadingIndicator(child: LinearProgressIndicator())),
            if (_error != null)
              Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
          ],
        )),
        actions: [
          TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: Text(locals.ok)),
        ],
      ),
    );
  }
}
