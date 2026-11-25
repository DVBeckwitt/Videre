import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> showSavedSongTitleEditor(
  BuildContext context, {
  required MusicLibraryEntry entry,
  required bool Function() isCurrent,
  required Future<bool> Function(String? title) onSave,
  bool inPlayer = false,
}) {
  final app = context.read<AppCubit>();
  return showDialog<void>(
    context: context,
    useRootNavigator: !inPlayer,
    builder: (_) => BlocListener<AppCubit, AppState>(
      bloc: app,
      listenWhen: (_, __) => !isCurrent(),
      listener: (context, _) {
        final route = ModalRoute.of(context);
        if (route != null && route.isActive)
          route.navigator?.removeRoute(route);
      },
      child: Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: _SavedSongTitleDialog(
            entry: entry, onSave: onSave, inPlayer: inPlayer),
      ),
    ),
  );
}

class _SavedSongTitleDialog extends StatefulWidget {
  final MusicLibraryEntry entry;
  final Future<bool> Function(String? title) onSave;
  final bool inPlayer;

  const _SavedSongTitleDialog({
    required this.entry,
    required this.onSave,
    required this.inPlayer,
  });

  @override
  State<_SavedSongTitleDialog> createState() => _SavedSongTitleDialogState();
}

class _SavedSongTitleDialogState extends State<_SavedSongTitleDialog> {
  late final _text = TextEditingController(text: widget.entry.displayTitle);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (!_saving) Navigator.of(context).pop();
  }

  void _submit() {
    if (_saving) return;
    final title = normalizeSavedSongTitle(_text.text);
    if (title == null) {
      setState(() {
        _error = AppLocalizations.of(context)!.musicSavedSongTitleInvalid;
      });
      return;
    }
    _write(title);
  }

  Future<void> _write(String? title) async {
    if (_saving) return;
    final route = ModalRoute.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    var applied = false;
    try {
      applied = await widget.onSave(title);
    } catch (_) {
      // Keep the current input available for retry when writing fails.
    }
    if (!mounted || !route.isActive) return;
    if (applied) {
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
      return;
    }
    setState(() {
      _saving = false;
      _error = AppLocalizations.of(context)!.musicLibraryActionError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final dialog = AlertDialog(
      scrollable: true,
      title: Text(locals.musicEditSavedSongTitle),
      content: TextField(
        key: const ValueKey('music-saved-song-title-input'),
        controller: _text,
        enabled: !_saving,
        autofocus: true,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: locals.musicSavedSongTitle,
          errorText: _error,
          errorMaxLines: 3,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        if (widget.entry.savedTitle != null)
          TextButton(
            onPressed: _saving ? null : () => _write(null),
            child: Text(locals.musicResetSavedSongTitle),
          ),
        TextButton(
          onPressed: _saving ? null : _dismiss,
          child: Text(locals.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: Text(locals.save),
        ),
      ],
    );
    return PopScope(
      canPop: !_saving,
      child: widget.inPlayer
          ? PlayerModalBackHandler(priority: 5, onBack: _dismiss, child: dialog)
          : dialog,
    );
  }
}
