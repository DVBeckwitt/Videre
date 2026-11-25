import 'dart:math' as math;

import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_playlist_folder_service.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

typedef _FolderCommand = Future<void> Function();
typedef _Destination = ({String? folderId});

abstract final class MusicPlaylistFolderActions {
  static Future<void> create(
    BuildContext context,
    MusicPlaylistFolderService service, {
    required String? parentId,
    required bool Function() isCurrent,
  }) async {
    if (!context.mounted || !isCurrent()) return;
    final locals = AppLocalizations.of(context)!;
    final name = await _show<String>(context, isCurrent,
        (_) => _FolderNameDialog(title: locals.musicPlaylistNewFolder));
    if (name == null || !context.mounted) return;
    await _mutate(context, isCurrent, () async {
      await service.createFolder(name,
          parentId: parentId, isCurrent: isCurrent);
    });
  }

  static Widget folderMenu(
    BuildContext context,
    MusicPlaylistFolderService service,
    MusicPlaylistFolder folder, {
    required bool Function() isCurrent,
  }) {
    final locals = AppLocalizations.of(context)!;
    return PopupMenuButton<_FolderCommand>(
      key: ValueKey('music-playlist-folder-actions-${folder.id}'),
      tooltip: locals.musicPlaylistFolderActions,
      onSelected: (command) => command(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: () => _rename(context, service, folder, isCurrent),
          child: Text(locals.musicPlaylistRenameFolder),
        ),
        PopupMenuItem(
          value: () => _moveFolder(context, service, folder, isCurrent),
          child: Text(locals.musicPlaylistMoveFolder),
        ),
        PopupMenuItem(
          value: () => _remove(context, service, folder, isCurrent),
          child: Text(locals.musicPlaylistRemoveFolder),
        ),
      ],
    );
  }

  static Widget movePlaylistButton(
    BuildContext context,
    MusicPlaylistFolderService service,
    PlaylistReference playlist, {
    required bool Function() isCurrent,
  }) {
    final locals = AppLocalizations.of(context)!;
    return IconButton(
      key: ValueKey('music-playlist-move-${playlist.playlistId}'),
      tooltip: locals.musicPlaylistMoveToFolder,
      icon: const Icon(Icons.drive_file_move_outline),
      onPressed: () async {
        if (!context.mounted || !isCurrent()) return;
        final snapshot = service.snapshot;
        final destination = await _show<_Destination>(
            context,
            isCurrent,
            (_) => _FolderDestinationDialog(
                  title: locals.musicPlaylistMoveToFolder,
                  folders: snapshot.folders,
                  currentFolderId: snapshot.folderFor(playlist),
                ));
        if (destination == null || !context.mounted) return;
        await _mutate(
            context,
            isCurrent,
            () => service.movePlaylist(playlist, destination.folderId,
                isCurrent: isCurrent));
      },
    );
  }

  static Future<void> _rename(
    BuildContext context,
    MusicPlaylistFolderService service,
    MusicPlaylistFolder folder,
    bool Function() isCurrent,
  ) async {
    if (!context.mounted || !isCurrent()) return;
    final locals = AppLocalizations.of(context)!;
    final name = await _show<String>(
        context,
        isCurrent,
        (_) => _FolderNameDialog(
              title: locals.musicPlaylistRenameFolder,
              initialName: folder.name,
            ));
    if (name == null || name == folder.name || !context.mounted) return;
    await _mutate(context, isCurrent,
        () => service.renameFolder(folder.id, name, isCurrent: isCurrent));
  }

  static Future<void> _moveFolder(
    BuildContext context,
    MusicPlaylistFolderService service,
    MusicPlaylistFolder folder,
    bool Function() isCurrent,
  ) async {
    if (!context.mounted || !isCurrent()) return;
    final locals = AppLocalizations.of(context)!;
    final snapshot = service.snapshot;
    final current =
        snapshot.folders.where((item) => item.id == folder.id).firstOrNull;
    if (current == null) return;
    final destination = await _show<_Destination>(
        context,
        isCurrent,
        (_) => _FolderDestinationDialog(
              title: locals.musicPlaylistMoveFolder,
              folders: snapshot.folders,
              currentFolderId: current.parentId,
              canBrowse: (id) =>
                  id == current.parentId ||
                  snapshot.canMoveFolder(folder.id, id),
              canMoveTo: (id) => snapshot.canMoveFolder(folder.id, id),
            ));
    if (destination == null || !context.mounted) return;
    await _mutate(
        context,
        isCurrent,
        () => service.moveFolder(folder.id, destination.folderId,
            isCurrent: isCurrent));
  }

  static Future<void> _remove(
    BuildContext context,
    MusicPlaylistFolderService service,
    MusicPlaylistFolder folder,
    bool Function() isCurrent,
  ) async {
    if (!context.mounted || !isCurrent()) return;
    final locals = AppLocalizations.of(context)!;
    final confirmed = await _show<bool>(context, isCurrent, (dialogContext) {
      return AlertDialog(
        scrollable: true,
        title: Text(locals.musicPlaylistRemoveFolderConfirm(folder.name)),
        content: Text(locals.musicPlaylistRemoveFolderBody),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(locals.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(locals.musicPlaylistRemoveFolder),
          ),
        ],
      );
    });
    if (confirmed != true || !context.mounted) return;
    await _mutate(context, isCurrent,
        () => service.removeFolder(folder.id, isCurrent: isCurrent));
  }

  static Future<T?> _show<T>(BuildContext context, bool Function() isCurrent,
      WidgetBuilder builder) async {
    if (!context.mounted || !isCurrent()) return null;
    final app = context.read<AppCubit>();
    final navigator = Navigator.of(context);
    final route = DialogRoute<T>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (dialogContext) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: builder(dialogContext),
      ),
    );
    final changes = app.stream.listen((_) {
      if ((!context.mounted || !isCurrent()) &&
          navigator.mounted &&
          route.isActive) {
        navigator.removeRoute(route);
      }
    });
    try {
      return await navigator.push(route);
    } finally {
      await changes.cancel();
    }
  }

  static Future<void> _mutate(BuildContext context, bool Function() isCurrent,
      _FolderCommand command) async {
    if (!context.mounted || !isCurrent()) return;
    try {
      await command();
    } catch (_) {
      if (!context.mounted || !isCurrent()) return;
      final message = AppLocalizations.of(context)!.musicLibraryActionError;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }
}

class _FolderNameDialog extends StatefulWidget {
  final String title;
  final String initialName;

  const _FolderNameDialog({required this.title, this.initialName = ''});

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late String _name = widget.initialName;

  void _submit() {
    if (normalizeMusicPlaylistFolderName(_name) case final name?) {
      Navigator.of(context).pop(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final canSave = normalizeMusicPlaylistFolderName(_name) != null;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextFormField(
          key: const ValueKey('music-playlist-folder-name'),
          initialValue: widget.initialName,
          autofocus: true,
          decoration: InputDecoration(
            labelText: locals.name,
            errorText: !canSave && _name.trim().isNotEmpty
                ? locals.musicPlaylistFolderNameInvalid(
                    musicPlaylistFolderNameLimit)
                : null,
          ),
          onChanged: (value) => setState(() => _name = value),
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(locals.cancel),
        ),
        TextButton(
          key: const ValueKey('music-playlist-folder-name-save'),
          onPressed: canSave ? _submit : null,
          child: Text(locals.save),
        ),
      ],
    );
  }
}

class _FolderDestinationDialog extends StatefulWidget {
  final String title;
  final List<MusicPlaylistFolder> folders;
  final String? currentFolderId;
  final bool Function(String)? canBrowse;
  final bool Function(String?)? canMoveTo;

  const _FolderDestinationDialog({
    required this.title,
    required this.folders,
    required this.currentFolderId,
    this.canBrowse,
    this.canMoveTo,
  });

  @override
  State<_FolderDestinationDialog> createState() =>
      _FolderDestinationDialogState();
}

class _FolderDestinationDialogState extends State<_FolderDestinationDialog> {
  final _path = <MusicPlaylistFolder>[];

  void _back() {
    if (_path.isNotEmpty) setState(_path.removeLast);
  }

  void _open(MusicPlaylistFolder folder) {
    if (_path.lastOrNull?.id == folder.parentId) {
      setState(() => _path.add(folder));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final current = _path.lastOrNull;
    final canMoveHere = current?.id != widget.currentFolderId &&
        (widget.canMoveTo?.call(current?.id) ?? true);
    final options = widget.folders
        .where((folder) =>
            folder.parentId == current?.id &&
            (widget.canBrowse?.call(folder.id) ?? true))
        .toList()
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName == 0 ? a.id.compareTo(b.id) : byName;
      });
    return PopScope<_Destination>(
      canPop: current == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(widget.title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                if (current != null) BackButton(onPressed: _back),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(current?.name ?? locals.musicPlaylists,
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                ),
              ]),
              if (options.isNotEmpty)
                SizedBox(
                  height: math.min(MediaQuery.sizeOf(context).height * 0.34,
                      options.length * 56.0),
                  child: ListView.builder(
                    key: ValueKey(current?.id),
                    primary: false,
                    itemCount: options.length,
                    itemBuilder: (_, index) {
                      final folder = options[index];
                      return ListTile(
                        key: ValueKey(
                            'music-playlist-folder-destination-${folder.id}'),
                        autofocus: index == 0,
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(folder.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(folder),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: !canMoveHere && options.isEmpty,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
          TextButton(
            key: const ValueKey('music-playlist-folder-move-here'),
            autofocus: canMoveHere && options.isEmpty,
            onPressed: canMoveHere
                ? () => Navigator.of(context).pop((folderId: current?.id))
                : null,
            child: Text(locals.musicPlaylistMoveHere),
          ),
        ],
      ),
    );
  }
}
