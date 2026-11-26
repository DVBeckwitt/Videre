import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/local_music_lyrics_authoring.dart';
import 'package:clipious/music/services/music_timed_lyrics_draft.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';

/// Returns true after saving or removing the song's authored lyrics.
Future<bool?> showMusicTimedLyricsEditor(
  BuildContext context, {
  required String songTitle,
  required String initialText,
  required Duration playbackDuration,
  required bool Function() isCurrent,
  required Duration Function() playbackPosition,
  required Future<bool> Function(String) save,
  Future<bool> Function()? remove,
  Widget? playbackControl,
}) {
  if (!isCurrent() || playbackDuration.inMilliseconds < 1) {
    return Future.value(false);
  }
  return _showLyricsEditor(
    context,
    songTitle: songTitle,
    initialText: initialText,
    isCurrent: isCurrent,
    save: save,
    remove: remove,
    timing: (
      duration: playbackDuration,
      position: playbackPosition,
      playbackControl: playbackControl,
    ),
  );
}

/// Returns true after saving or removing the song's plain lyrics draft.
Future<bool?> showMusicPlainLyricsEditor(
  BuildContext context, {
  required String songTitle,
  required String initialText,
  required bool Function() isCurrent,
  required Future<bool> Function(String) save,
  Future<bool> Function()? remove,
}) {
  if (!isCurrent()) return Future.value(false);
  return _showLyricsEditor(
    context,
    songTitle: songTitle,
    initialText: initialText,
    isCurrent: isCurrent,
    save: save,
    remove: remove,
  );
}

typedef _LyricsTiming = ({
  Duration duration,
  Duration Function() position,
  Widget? playbackControl,
});

Future<bool?> _showLyricsEditor(
  BuildContext context, {
  required String songTitle,
  required String initialText,
  required bool Function() isCurrent,
  required Future<bool> Function(String) save,
  Future<bool> Function()? remove,
  _LyricsTiming? timing,
}) =>
    Navigator.of(context).push(MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (context) => _MusicLyricsEditor(
        songTitle: songTitle,
        initialText: initialText,
        isCurrent: isCurrent,
        save: save,
        remove: remove,
        timing: timing,
      ),
    ));

class _MusicLyricsEditor extends StatefulWidget {
  final String songTitle;
  final String initialText;
  final bool Function() isCurrent;
  final Future<bool> Function(String) save;
  final Future<bool> Function()? remove;
  final _LyricsTiming? timing;

  const _MusicLyricsEditor({
    required this.songTitle,
    required this.initialText,
    required this.isCurrent,
    required this.save,
    required this.remove,
    required this.timing,
  });

  @override
  State<_MusicLyricsEditor> createState() => _MusicLyricsEditorState();
}

class _MusicLyricsEditorState extends State<_MusicLyricsEditor> {
  late final _draft = TextEditingController.fromValue(
    TextEditingValue(
      text: widget.initialText,
      selection: const TextSelection.collapsed(offset: 0),
    ),
  );
  bool _writing = false;
  String? _error;

  AppLocalizations get _locals => AppLocalizations.of(context)!;
  bool get _plain => widget.timing == null;
  String get _removeLabel =>
      _plain ? _locals.musicLyricsRemovePlain : _locals.musicLyricsRemoveTimed;

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  void _close() {
    if (!_writing) Navigator.of(context).pop();
  }

  bool _mayEdit() {
    if (_writing) return false;
    if (widget.isCurrent()) return true;
    setState(() => _error = _locals.musicLyricsEditUnavailable);
    return false;
  }

  void _stamp(_LyricsTiming timing, {required bool word}) {
    if (!_mayEdit()) return;
    final edit = stampMusicTimedLyricsDraft(
      _draft.text,
      caretOffset: _draft.selection.extentOffset,
      position: timing.position(),
      playbackDuration: timing.duration,
      word: word,
    );
    if (edit == null) {
      setState(() => _error = _locals.musicLyricsDraftInvalid);
      return;
    }
    _draft.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection.collapsed(offset: edit.caretOffset),
    );
    if (_error != null) setState(() => _error = null);
  }

  Future<void> _save() async {
    if (!_mayEdit()) return;
    final timing = widget.timing;
    final text = timing == null
        ? validatedMusicPlainLyricsDraft(_draft.text)
        : validatedMusicTimedLyricsDraft(_draft.text, timing.duration);
    if (text == null) {
      setState(() => _error = _plain
          ? _locals.musicLyricsPlainDraftInvalid
          : _locals.musicLyricsDraftInvalid);
      return;
    }
    await _write(() => widget.save(text));
  }

  Future<void> _confirmRemoval() async {
    final remove = widget.remove;
    if (remove == null || !_mayEdit()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => PlayerModalBackHandler(
        child: AlertDialog(
          title: Text(_removeLabel),
          content: Text(_plain
              ? _locals.musicLyricsRemovePlainConfirm
              : _locals.musicLyricsRemoveTimedConfirm),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(_locals.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(_removeLabel),
            ),
          ],
        ),
      ),
    );
    if (mounted && confirmed == true && _mayEdit()) await _write(remove);
  }

  Future<void> _write(Future<bool> Function() write) async {
    setState(() {
      _writing = true;
      _error = null;
    });
    var changed = false;
    try {
      changed = await write();
    } catch (_) {
      // The editor retains the draft so the listener can retry.
    }
    if (!mounted) return;
    if (changed) {
      final route = ModalRoute.of<bool>(context)!;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop(true);
      } else if (route.isActive) {
        navigator.removeRoute(route, true);
      }
    } else {
      setState(() {
        _writing = false;
        _error = widget.isCurrent()
            ? _locals.musicLyricsWriteFailed
            : _locals.musicLyricsEditUnavailable;
      });
    }
  }

  @override
  Widget build(BuildContext context) => PlayerModalBackHandler(
        onBack: _close,
        child: PopScope<bool>(
          canPop: !_writing,
          child: Scaffold(
            appBar: AppBar(
              leading: CloseButton(onPressed: _close),
              title: Text(_plain
                  ? _locals.musicLyricsEditPlain
                  : _locals.musicLyricsEditTimed),
              actions: [
                if (widget.remove != null)
                  IconButton(
                    tooltip: _removeLabel,
                    onPressed: _writing ? null : _confirmRemoval,
                    icon: const Icon(Icons.delete_outline),
                  ),
                if (_writing)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: MotionLoadingIndicator(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  TextButton(onPressed: _save, child: Text(_locals.save)),
              ],
            ),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      Text(widget.songTitle,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(_plain
                          ? _locals.musicLyricsPlainEditInstructions
                          : _locals.musicLyricsEditInstructions),
                      if (widget.timing case final timing?) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (timing.playbackControl case final playback?)
                              playback,
                            OutlinedButton.icon(
                              onPressed: _writing
                                  ? null
                                  : () => _stamp(timing, word: false),
                              icon: const Icon(Icons.timer_outlined),
                              label: Text(_locals.musicLyricsStampLine),
                            ),
                            OutlinedButton.icon(
                              onPressed: _writing
                                  ? null
                                  : () => _stamp(timing, word: true),
                              icon: const Icon(Icons.short_text),
                              label: Text(_locals.musicLyricsStampWord),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        controller: _draft,
                        enabled: !_writing,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        minLines: 7,
                        maxLines: 15,
                        onChanged: (_) {
                          if (_error != null) setState(() => _error = null);
                        },
                        decoration: InputDecoration(
                          labelText: _plain
                              ? _locals.musicLyricsPlain
                              : _locals.musicLyricsDraftLabel,
                          alignLabelWithHint: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      if (_error case final error?)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(error,
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
