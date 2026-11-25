import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/named_music_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

String musicSavedQueueLabel(AppLocalizations labels, NamedMusicQueue queue) =>
    queue.usesDefaultName ? labels.musicPreviousQueue : queue.name;

Future<void> showMusicSavedQueues(BuildContext context) async {
  final app = context.read<AppCubit>();
  final player = context.read<PlayerCubit>();
  final owner = app.state;
  if (owner.globalLoading || owner.sessionRecoveryRequired) return;
  await showDialog<void>(
    context: context,
    builder: (_) => BlocProvider.value(
      value: player,
      child: _SavedQueuesDialog(app: app, player: player, owner: owner),
    ),
  );
}

enum _QueueAction { save, rename, delete }

class _SavedQueuesDialog extends StatefulWidget {
  const _SavedQueuesDialog({
    required this.app,
    required this.player,
    required this.owner,
  });

  final AppCubit app;
  final PlayerCubit player;
  final AppState owner;

  @override
  State<_SavedQueuesDialog> createState() => _SavedQueuesDialogState();
}

class _SavedQueuesDialogState extends State<_SavedQueuesDialog> {
  final _name = TextEditingController();
  ({_QueueAction action, NamedMusicQueue? queue})? _form;
  String? _resumingId;
  bool _busy = false;
  String? _error;

  bool _isCurrent(AppState state) =>
      !widget.app.isClosed &&
      !state.globalLoading &&
      !state.sessionRecoveryRequired &&
      state.profileId == widget.owner.profileId &&
      state.sessionRevision == widget.owner.sessionRevision &&
      state.server == widget.owner.server;

  @override
  void initState() {
    super.initState();
    if (!_isCurrent(widget.app.state)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _dismissStaleDialog());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _dismissStaleDialog() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _openForm(_QueueAction action, [NamedMusicQueue? queue]) {
    if (_busy || !_isCurrent(widget.app.state)) return;
    if (action == _QueueAction.rename) {
      _name.text = musicSavedQueueLabel(AppLocalizations.of(context)!, queue!);
    } else {
      _name.clear();
    }
    setState(() {
      _form = (action: action, queue: queue);
      _error = null;
    });
  }

  void _closeForm() => setState(() {
        _form = null;
        _error = null;
      });

  Future<void> _run(Future<String?> Function() action,
      {String? resumingId}) async {
    if (_busy || !_isCurrent(widget.app.state) || widget.player.isClosed) {
      return;
    }
    final labels = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _resumingId = resumingId;
      _error = null;
    });
    String? error;
    try {
      error = await action();
    } catch (_) {
      error = labels.musicLibraryActionError;
    }
    if (!mounted || !_isCurrent(widget.app.state)) return;
    setState(() {
      _busy = false;
      _error = error;
      if (error == null) _form = null;
    });
    if (error == null &&
        resumingId != null &&
        ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _resume(NamedMusicQueue queue, AppLocalizations labels) => _run(
        () async => await widget.player.resumeNamedMusicQueue(queue.id) ==
                NamedMusicQueueResumeResult.restored
            ? null
            : labels.musicSavedQueueUnavailable,
        resumingId: queue.id,
      );

  Future<void> _submit(_QueueAction action, NamedMusicQueue? queue) async {
    final player = widget.player;
    final name = _name.text.trim();
    if (action != _QueueAction.delete && name.isEmpty) return;
    final labels = AppLocalizations.of(context)!;
    await _run(() async {
      final changed = switch (action) {
        _QueueAction.save => await player.saveNamedMusicQueue(name) != null,
        _QueueAction.rename =>
          await player.renameNamedMusicQueue(queue!.id, name),
        _QueueAction.delete => await player.deleteNamedMusicQueue(queue!.id),
      };
      return changed ? null : labels.musicLibraryActionError;
    });
  }

  Widget _feedback() => Column(
        children: [
          if (_error case final message?)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(message,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
        ],
      );

  Widget _queueList(AppLocalizations labels, bool canSave) {
    final player = widget.player;
    final queues = player.namedMusicQueues;
    return AlertDialog(
      title: Text(labels.musicSavedQueues),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(children: [
          if (queues.isEmpty) Text(labels.musicSavedQueuesEmpty),
          for (final (index, queue) in queues.indexed) ...[
            _queueRow(queue, labels,
                autofocus: index == 0,
                active: queue.id == player.activeNamedMusicQueueId),
            if (_resumingId == queue.id) _feedback(),
          ],
        ]),
      ),
      actions: [
        TextButton(
          autofocus: queues.isEmpty && !canSave,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
        if (canSave)
          TextButton.icon(
            autofocus: queues.isEmpty,
            onPressed: _busy ? null : () => _openForm(_QueueAction.save),
            icon: const Icon(Icons.add),
            label: Text(labels.musicSaveCurrentQueue),
          ),
      ],
    );
  }

  Widget _queueRow(NamedMusicQueue queue, AppLocalizations labels,
      {required bool autofocus, required bool active}) {
    final title = musicSavedQueueLabel(labels, queue);
    final snapshot = queue.snapshot;
    final description = [
      if (active) labels.musicSavedQueueActive,
      labels
          .musicTrackCount(snapshot.videos.length + snapshot.offlineIds.length),
      if (snapshot.queueTitle case final source? when source != title) source,
    ].join(' · ');
    return ListTile(
      key: ValueKey(('music-saved-queue', queue.id)),
      autofocus: autofocus,
      contentPadding: EdgeInsets.zero,
      leading: Icon(active ? Icons.check_circle_outline : Icons.queue_music),
      enabled: !_busy,
      title: Text(title),
      subtitle: Text(description),
      onTap: () => _resume(queue, labels),
      trailing: MenuAnchor(
        consumeOutsideTap: true,
        crossAxisUnconstrained: false,
        menuChildren: [
          MenuItemButton(
            onPressed: () {
              if (mounted) _openForm(_QueueAction.rename, queue);
            },
            child: Text(labels.musicRenameSavedQueue),
          ),
          MenuItemButton(
            onPressed: () {
              if (mounted) _openForm(_QueueAction.delete, queue);
            },
            child: Text(labels.musicDeleteSavedQueue),
          ),
        ],
        builder: (context, controller, _) => IconButton(
          key: ValueKey(('music-saved-queue-actions', queue.id)),
          tooltip: labels.musicSavedQueueActions(title),
          onPressed: _busy
              ? null
              : () =>
                  controller.isOpen ? controller.close() : controller.open(),
          icon: const Icon(Icons.more_vert),
        ),
      ),
    );
  }

  Widget _queueForm(AppLocalizations labels, bool canSave, _QueueAction action,
      NamedMusicQueue? queue) {
    final deleting = action == _QueueAction.delete;
    final canSubmit = !_busy &&
        (deleting ||
            _name.text.trim().isNotEmpty &&
                (action != _QueueAction.save || canSave));
    return AlertDialog(
      scrollable: true,
      title: Text(switch (action) {
        _QueueAction.save => labels.musicSaveCurrentQueue,
        _QueueAction.rename => labels.musicRenameSavedQueue,
        _QueueAction.delete => labels.musicDeleteSavedQueue,
      }),
      content: SizedBox(
        width: 420,
        child: Column(children: [
          if (deleting)
            Text(labels.musicDeleteSavedQueueConfirmation(
                musicSavedQueueLabel(labels, queue!)))
          else
            TextField(
              key: const ValueKey('music-saved-queue-name'),
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: labels.name),
              onChanged: (_) => setState(() {}),
              onSubmitted: canSubmit ? (_) => _submit(action, queue) : null,
            ),
          _feedback(),
        ]),
      ),
      actions: [
        TextButton(
          autofocus: deleting,
          onPressed: _busy ? null : _closeForm,
          child: Text(labels.cancel),
        ),
        TextButton(
          onPressed: canSubmit ? () => _submit(action, queue) : null,
          child: Text(deleting ? labels.delete : labels.save),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    return BlocListener<AppCubit, AppState>(
      bloc: widget.app,
      listenWhen: (_, state) => !_isCurrent(state),
      listener: (_, __) => _dismissStaleDialog(),
      child: ValueListenableBuilder(
        valueListenable: widget.player.namedMusicQueuesRevision,
        builder: (context, _, __) {
          if (!_isCurrent(widget.app.state)) return const SizedBox.shrink();
          final canSave = context
              .select((PlayerCubit player) => player.canSaveNamedMusicQueue);
          final form = _form;
          return PopScope(
            canPop: !_busy,
            child: form == null
                ? _queueList(labels, canSave)
                : _queueForm(labels, canSave, form.action, form.queue),
          );
        },
      ),
    );
  }
}
