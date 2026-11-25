import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../services/music_passage_bookmarks.dart';

Future<void> showMusicPassageBookmarksSheet(
  BuildContext context, {
  required MusicPassageBookmarks store,
  required String recordingId,
  required String occurrenceId,
  required bool Function() isCurrent,
  required Duration? Function() capturePosition,
  required bool Function(PassageBookmark) canJump,
  required Future<bool> Function(PassageBookmark) jump,
}) {
  final app = context.read<AppCubit?>();
  final player = context.read<PlayerCubit?>();
  final playbackChanges = player?.stream.distinct(
    (before, after) =>
        before.currentQueueId == after.currentQueueId &&
        before.videos == after.videos &&
        before.offlineVideos == after.offlineVideos &&
        before.isAudio == after.isAudio &&
        before.isMini == after.isMini &&
        before.isHidden == after.isHidden &&
        before.isClosing == after.isClosing &&
        before.mediaEvent.state == after.mediaEvent.state,
  );
  return showSafeModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => StreamBuilder<AppState>(
      stream: app?.stream,
      builder: (context, _) => StreamBuilder<PlayerState>(
        stream: playbackChanges,
        builder: (context, _) => PlayerModalBackHandler(
          child: _activateWithRemote(
            _PassageBookmarksSheet(
              store: store,
              recordingId: recordingId,
              occurrenceId: occurrenceId,
              isCurrent: isCurrent,
              capturePosition: capturePosition,
              canJump: canJump,
              jump: jump,
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _activateWithRemote(Widget child) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: child,
    );

String _positionLabel(Duration position) {
  final hours = position.inHours > 0 ? '${position.inHours}:' : '';
  final minutes = (position.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (position.inSeconds % 60).toString().padLeft(2, '0');
  final milliseconds = position.inMilliseconds % Duration.millisecondsPerSecond;
  final fraction =
      milliseconds == 0 ? '' : '.${milliseconds.toString().padLeft(3, '0')}';
  return '$hours$minutes:$seconds$fraction';
}

class _PassageBookmarksSheet extends StatefulWidget {
  final MusicPassageBookmarks store;
  final String recordingId;
  final String occurrenceId;
  final bool Function() isCurrent;
  final Duration? Function() capturePosition;
  final bool Function(PassageBookmark) canJump;
  final Future<bool> Function(PassageBookmark) jump;

  const _PassageBookmarksSheet({
    required this.store,
    required this.recordingId,
    required this.occurrenceId,
    required this.isCurrent,
    required this.capturePosition,
    required this.canJump,
    required this.jump,
  });

  @override
  State<_PassageBookmarksSheet> createState() => _PassageBookmarksSheetState();
}

class _PassageBookmarksSheetState extends State<_PassageBookmarksSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _editName({PassageBookmark? bookmark}) async {
    if (_busy ||
        !widget.isCurrent() ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final locals = AppLocalizations.of(context)!;
    final position = bookmark?.position ?? widget.capturePosition();
    if (position == null) {
      setState(() => _error = locals.musicPassageBookmarksSessionChanged);
      return;
    }
    final name = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (_) => PlayerModalBackHandler(
        priority: 5,
        child: _activateWithRemote(
          _BookmarkNameDialog(
            title: bookmark == null
                ? locals.musicPassageBookmarkAdd
                : locals.musicPassageBookmarkRename,
            position: position,
            name: bookmark?.name ?? '',
          ),
        ),
      ),
    );
    if (name == null || name == bookmark?.name || !mounted) return;
    await _apply(() {
      if (bookmark != null) {
        return widget.store.rename(bookmark, name, isCurrent: widget.isCurrent);
      }
      return widget.store.add(
        recordingId: widget.recordingId,
        occurrenceId: widget.occurrenceId,
        position: position,
        name: name,
        isCurrent: widget.isCurrent,
      );
    }, failure: locals.musicPassageBookmarkSaveFailed);
  }

  Future<void> _apply(
    Future<bool> Function() action, {
    required String failure,
    bool closeAfter = false,
  }) async {
    if (_busy || !widget.isCurrent()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var succeeded = false;
    try {
      succeeded = await action();
    } catch (_) {
      // The sheet reports a failed write or seek and leaves the action available.
    }
    if (!mounted) return;
    if (succeeded && closeAfter && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _error = succeeded ? null : failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final current = widget.isCurrent();
    final bookmarks = current
        ? widget.store.list(widget.recordingId)
        : const <PassageBookmark>[];
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .75,
      ),
      child: Column(
        key: const ValueKey('music-passage-bookmarks-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              locals.musicPassageBookmarks,
              style: theme.textTheme.headlineSmall,
            ),
          ),
          if (current)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('music-passage-bookmark-add'),
                  onPressed: _busy ? null : () => _editName(),
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: Text(locals.musicPassageBookmarkAdd),
                ),
              ),
            ),
          if (_busy && current) const LinearProgressIndicator(),
          if (_error != null && current)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ),
          if (bookmarks.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Text(
                current
                    ? locals.musicPassageBookmarksEmpty
                    : locals.musicPassageBookmarksSessionChanged,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: bookmarks.length,
                itemBuilder: (context, index) {
                  final bookmark = bookmarks[index];
                  final canJump = widget.canJump(bookmark);
                  return ListTile(
                    key: ValueKey(('music-passage-bookmark', bookmark.id)),
                    title: Text(bookmark.name),
                    subtitle: Text(
                      [
                        _positionLabel(bookmark.position),
                        if (!canJump) locals.musicPassageBookmarkUnavailable,
                      ].join('\n'),
                    ),
                    onTap: _busy || !canJump
                        ? null
                        : () => _apply(
                              () => widget.jump(bookmark),
                              failure: locals.musicPassageBookmarkUnavailable,
                              closeAfter: true,
                            ),
                    trailing: PopupMenuButton<_BookmarkAction>(
                      enabled: !_busy,
                      onSelected: (action) {
                        switch (action) {
                          case _BookmarkAction.rename:
                            _editName(bookmark: bookmark);
                          case _BookmarkAction.delete:
                            _apply(
                              () => widget.store.remove(
                                bookmark,
                                isCurrent: widget.isCurrent,
                              ),
                              failure: locals.musicPassageBookmarkSaveFailed,
                            );
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: _BookmarkAction.rename,
                          child: PlayerModalBackHandler(
                            priority: 5,
                            child: Text(locals.musicPassageBookmarkRename),
                          ),
                        ),
                        PopupMenuItem(
                          value: _BookmarkAction.delete,
                          child: Text(locals.musicPassageBookmarkDelete),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

enum _BookmarkAction { rename, delete }

class _BookmarkNameDialog extends StatefulWidget {
  final String title;
  final Duration position;
  final String name;

  const _BookmarkNameDialog({
    required this.title,
    required this.position,
    required this.name,
  });

  @override
  State<_BookmarkNameDialog> createState() => _BookmarkNameDialogState();
}

class _BookmarkNameDialogState extends State<_BookmarkNameDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    if (_form.currentState!.validate()) {
      Navigator.pop(context, _name.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_positionLabel(widget.position)),
            TextFormField(
              key: const ValueKey('music-passage-bookmark-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: locals.name),
              validator: (value) => value == null || value.trim().isEmpty
                  ? locals.musicPassageBookmarkNameRequired
                  : null,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(locals.cancel),
        ),
        FilledButton(onPressed: _save, child: Text(locals.save)),
      ],
    );
  }
}
