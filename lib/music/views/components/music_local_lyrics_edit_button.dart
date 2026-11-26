import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/local_music_lyrics_authoring.dart';
import 'package:clipious/player/states/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_timed_lyrics_editor.dart';

class MusicLocalLyricsEditButton extends StatefulWidget {
  final LocalMusicLyricsAuthoring authoring;
  final String songTitle;
  final MusicLyrics lyrics;
  final Future<bool> Function() canReadRecording;
  final VoidCallback onChanged;

  const MusicLocalLyricsEditButton({
    super.key,
    required this.authoring,
    required this.songTitle,
    required this.lyrics,
    required this.canReadRecording,
    required this.onChanged,
  });

  @override
  State<MusicLocalLyricsEditButton> createState() =>
      _MusicLocalLyricsEditButtonState();
}

class _MusicLocalLyricsEditButtonState
    extends State<MusicLocalLyricsEditButton> {
  bool _opening = false;

  Future<void> _edit({required bool plain}) async {
    final target = widget;
    final authoring = target.authoring;
    if (_opening || !authoring.current) return;
    _opening = true;
    try {
      final readable = await target.canReadRecording();
      if (!mounted || !authoring.current) return;
      if (!readable) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(
                AppLocalizations.of(context)!.musicLyricsEditUnavailable)));
        return;
      }
      final changed = plain
          ? await _openPlainEditor(target)
          : await _openTimedEditor(target);
      if (changed == true && mounted && authoring.current) target.onChanged();
    } finally {
      _opening = false;
    }
  }

  Future<bool?> _openTimedEditor(MusicLocalLyricsEditButton target) {
    final authoring = target.authoring;
    final player = context.read<PlayerCubit>();
    final saved = authoring.readDraft();
    return showMusicTimedLyricsEditor(
      context,
      songTitle: target.songTitle,
      initialText: saved ?? musicTimedLyricsDraftFrom(target.lyrics),
      playbackDuration: authoring.duration,
      isCurrent: () => authoring.current,
      playbackPosition: () => player.state.position,
      playbackControl: BlocSelector<PlayerCubit, PlayerState, bool>(
        bloc: player,
        selector: (state) => state.isPlaying,
        builder: (context, playing) {
          final locals = AppLocalizations.of(context)!;
          return IconButton(
            tooltip: playing ? locals.musicPause : locals.musicPlay,
            onPressed: () {
              if (authoring.current) player.togglePlaying();
            },
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          );
        },
      ),
      save: (text) async =>
          await target.canReadRecording() &&
          await authoring.save(text, previousDraft: saved),
      remove: saved == null
          ? null
          : () async =>
              await target.canReadRecording() &&
              await authoring.remove(previousDraft: saved),
    );
  }

  Future<bool?> _openPlainEditor(MusicLocalLyricsEditButton target) {
    final authoring = target.authoring;
    final saved = authoring.readPlainDraft();
    return showMusicPlainLyricsEditor(
      context,
      songTitle: target.songTitle,
      initialText: saved ?? '',
      isCurrent: () => authoring.current,
      save: (text) async =>
          await target.canReadRecording() &&
          await authoring.savePlain(text, previousDraft: saved),
      remove: saved == null
          ? null
          : () async =>
              await target.canReadRecording() &&
              await authoring.removePlain(previousDraft: saved),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final current = widget.authoring.current;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('music-lyrics-edit-timed'),
          tooltip: locals.musicLyricsEditTimed,
          onPressed: current && widget.authoring.duration > Duration.zero
              ? () => _edit(plain: false)
              : null,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          key: const ValueKey('music-lyrics-edit-plain'),
          tooltip: locals.musicLyricsEditPlain,
          onPressed: current ? () => _edit(plain: true) : null,
          icon: const Icon(Icons.notes_outlined),
        ),
      ],
    );
  }
}
