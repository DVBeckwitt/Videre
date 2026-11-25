import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_library_actions.dart';

class MusicPlaylistRenameButton extends StatelessWidget {
  const MusicPlaylistRenameButton({
    super.key,
    required this.reference,
    required this.title,
  });

  final PlaylistReference reference;
  final String title;

  Future<void> _open(BuildContext context) async {
    final app = context.read<AppCubit>();
    final session = MusicLibrarySession(app);
    if (!session.isCurrent ||
        session.library.profileId != reference.profileId) {
      return;
    }
    final navigator = Navigator.of(context);
    final route = DialogRoute<void>(
      context: context,
      builder: (_) => _RenameMusicPlaylistDialog(
        title: title,
        rename: (name) => session.renamePlaylist(reference, name),
      ),
    );
    final changes = app.stream.listen((_) {
      if (!session.isCurrent && route.isActive && navigator.mounted) {
        navigator.removeRoute(route);
      }
    });
    try {
      await navigator.push(route);
    } finally {
      await changes.cancel();
    }
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: () => _open(context),
        icon: const Icon(Icons.edit_outlined),
        label: Text(AppLocalizations.of(context)!.musicRenamePlaylist),
      );
}

class _RenameMusicPlaylistDialog extends StatefulWidget {
  const _RenameMusicPlaylistDialog({required this.title, required this.rename});

  final String title;
  final Future<bool> Function(String) rename;

  @override
  State<_RenameMusicPlaylistDialog> createState() =>
      _RenameMusicPlaylistDialogState();
}

class _RenameMusicPlaylistDialogState
    extends State<_RenameMusicPlaylistDialog> {
  late final _name = TextEditingController(text: widget.title);
  bool _saving = false;
  bool _failed = false;

  bool get _canSave {
    final title = _name.text.trim();
    return !_saving && title.isNotEmpty && title != widget.title;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    var saved = false;
    try {
      saved = await widget.rename(_name.text);
    } catch (_) {
      // Keep the input available if the write fails.
    }
    if (!mounted) return;
    if (saved && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = false;
      _failed = !saved;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(locals.musicRenamePlaylist),
        content: TextField(
          controller: _name,
          autofocus: true,
          readOnly: _saving,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: locals.playListName,
            errorText: _failed ? locals.musicLibraryActionError : null,
            errorMaxLines: 3,
          ),
          onChanged: (_) => setState(() => _failed = false),
          onSubmitted: (_) => _save(),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
          TextButton(
            onPressed: _canSave ? _save : null,
            child: Text(locals.save),
          ),
        ],
      ),
    );
  }
}
