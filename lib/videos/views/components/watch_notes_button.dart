import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/models/media_event.dart';
import '../../../player/states/player.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../utils.dart';
import '../../services/watch_notes.dart';

/// Opens locally stored notes for this video, even without Watch metadata.
class WatchNotesButton extends StatelessWidget {
  final String videoId;
  final bool labeled;
  final Future<void> Function(Duration)? onStartAt;

  const WatchNotesButton({
    super.key,
    required this.videoId,
    this.labeled = false,
    this.onStartAt,
  });

  bool _canSeek(PlayerState state) {
    final video = state.currentlyPlaying;
    final download = state.offlineCurrentlyPlaying;
    return !state.isHidden &&
        !state.isClosing &&
        !state.isAudio &&
        (video?.videoId ?? download?.videoId) == videoId &&
        video?.liveNow != true &&
        (video?.lengthSeconds ?? download?.lengthSeconds ?? 0) > 0 &&
        state.mediaEvent.state != MediaState.error;
  }

  Future<void> _open(BuildContext context) async {
    final app = context.read<AppCubit>();
    final player = context.read<PlayerCubit>();
    final database = db;
    final profile = database.profileId;
    final revision = app.state.sessionRevision;

    bool isCurrent() =>
        !app.isClosed &&
        !player.isClosed &&
        identical(db, database) &&
        database.profileId == profile &&
        app.state.sessionRevision == revision &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired;

    if (!isCurrent()) return;
    final notes = WatchNotes.forVideo(database, videoId);
    final position = await showDialog<Duration>(
      context: context,
      builder: (_) => PlayerModalBackHandler(
        child: BlocBuilder<AppCubit, AppState>(
          bloc: app,
          builder: (context, _) => isCurrent()
              ? BlocSelector<PlayerCubit, PlayerState, bool>(
                  bloc: player,
                  selector: (state) => _canSeek(state) || onStartAt != null,
                  builder: (context, canSeek) => _WatchNotesDialog(
                    notes: notes,
                    isCurrent: isCurrent,
                    canSeek: canSeek,
                    playhead: () {
                      final state = player.state;
                      return _canSeek(state) &&
                              state.mediaEvent.state != MediaState.loading &&
                              state.mediaEvent.state != MediaState.idle
                          ? state.position
                          : null;
                    },
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
    if (position == null || !context.mounted || !isCurrent()) return;
    if (_canSeek(player.state)) {
      player.seek(position);
      if (player.state.isMini) player.showBigPlayer();
    } else if (onStartAt case final start?) {
      await start(position);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = AppLocalizations.of(context)!.watchNotes;
    final colors = Theme.of(context).colorScheme;
    const icon = Icon(Icons.sticky_note_2_outlined, size: 20);
    const key = ValueKey('watch-notes-open');
    return labeled
        ? FilledButton.tonalIcon(
            key: key,
            style: FilledButton.styleFrom(
              backgroundColor: colors.surfaceContainerHighest,
              foregroundColor: colors.onSurface,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: () => _open(context),
            icon: icon,
            label: Text(label),
          )
        : IconButton(
            key: key,
            onPressed: () => _open(context),
            icon: icon,
            tooltip: label,
          );
  }
}

class _WatchNotesDialog extends StatefulWidget {
  final WatchNotes notes;
  final bool Function() isCurrent;
  final bool canSeek;
  final Duration? Function() playhead;

  const _WatchNotesDialog({
    required this.notes,
    required this.isCurrent,
    required this.canSeek,
    required this.playhead,
  });

  @override
  State<_WatchNotesDialog> createState() => _WatchNotesDialogState();
}

class _WatchNotesDialogState extends State<_WatchNotesDialog> {
  WatchNote? _existing;
  String _text = '';
  Duration? _position;
  bool _editing = false;
  bool _includeTimestamp = false;
  bool _saving = false;
  bool _saveFailed = false;

  void _edit([WatchNote? note]) {
    setState(() {
      _existing = note;
      _text = note?.text ?? '';
      _position = note?.position ?? widget.playhead();
      _includeTimestamp =
          note == null ? _position != null : note.position != null;
      _editing = true;
      _saveFailed = false;
    });
  }

  Future<void> _save() async {
    if (_saving || _text.trim().isEmpty || !widget.isCurrent()) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await widget.notes.save(
        existing: _existing,
        text: _text,
        position: _includeTimestamp ? _position : null,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
    }
  }

  Widget _editor(AppLocalizations locals, MaterialLocalizations material) {
    return AlertDialog(
      scrollable: true,
      title: Text(
        _existing == null ? locals.watchNoteAdd : locals.watchNoteEdit,
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              autofocus: true,
              initialValue: _text,
              enabled: !_saving,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(labelText: locals.watchNoteText),
              onChanged: (value) => setState(() => _text = value),
            ),
            if (_position case final position?)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeTimestamp,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _includeTimestamp = value!),
                title: Text(locals.watchNoteIncludeTimestamp),
                subtitle: Text(prettyDurationCustom(position)),
              ),
            if (_saveFailed) Text(locals.watchNoteSaveFailed),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => setState(() => _editing = false),
          child: Text(material.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _saving || _text.trim().isEmpty ? null : _save,
          child: Text(locals.save),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    if (_editing) return _editor(locals, material);
    final notes = widget.notes.list();
    return AlertDialog(
      title: Text(locals.watchNotes),
      content: SizedBox(
        width: 440,
        child: notes.isEmpty
            ? Text(locals.watchNotesEmpty)
            : SizedBox(
                height: 280,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    final position = note.position;
                    final canJump = position != null && widget.canSeek;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      onTap: () {
                        if (!widget.isCurrent()) return;
                        if (canJump) {
                          Navigator.of(context).pop(position);
                        } else {
                          _edit(note);
                        }
                      },
                      leading:
                          canJump ? const Icon(Icons.play_arrow_rounded) : null,
                      title: Text(
                        note.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: position == null
                          ? null
                          : Text(prettyDurationCustom(position)),
                      trailing: IconButton(
                        tooltip: locals.watchNoteEdit,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(note),
                      ),
                    );
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(material.closeButtonLabel),
        ),
        FilledButton.icon(
          autofocus: true,
          onPressed: _edit,
          icon: const Icon(Icons.add),
          label: Text(locals.watchNoteAdd),
        ),
      ],
    );
  }
}
