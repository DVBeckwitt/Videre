import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class MusicLyricsButton extends StatefulWidget {
  final MusicLyricsLoader loader;
  const MusicLyricsButton({super.key, required this.loader});

  @override
  State<MusicLyricsButton> createState() => _MusicLyricsButtonState();
}

class _MusicLyricsButtonState extends State<MusicLyricsButton> {
  bool _opening = false;

  Future<void> _open() async {
    if (_opening) return;
    final app = context.read<AppCubit>();
    final player = context.read<PlayerCubit>();
    final database = db;
    final profile = database.profileId;
    final session = app.state;
    final generation = player.backendPlaybackGeneration;
    final state = player.state;
    final video = state.currentlyPlaying;
    final offline = state.offlineCurrentlyPlaying;
    final track = video?.musicMetadata ?? offline?.musicMetadata;
    final videoId = video?.videoId ?? offline?.videoId;
    if (track == null || videoId == null) return;

    bool isCurrent() {
      final current = player.state;
      return mounted &&
          !player.isClosed &&
          !app.isClosed &&
          identical(db, database) &&
          database.profileId == profile &&
          !app.state.globalLoading &&
          !app.state.sessionRecoveryRequired &&
          app.state.sessionRevision == session.sessionRevision &&
          app.state.profileId == session.profileId &&
          player.backendPlaybackGeneration == generation &&
          current.isAudio &&
          !current.isClosing &&
          !current.isHidden &&
          current.currentQueueId == state.currentQueueId &&
          current.currentlyPlaying?.videoId == video?.videoId &&
          current.offlineCurrentlyPlaying?.videoId == offline?.videoId;
    }

    if (!isCurrent()) return;
    _opening = true;
    try {
      if (!isLrclibEnabled()) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) {
            final locals = AppLocalizations.of(context)!;
            return PlayerModalBackHandler(
                child: AlertDialog(
              title: Text(locals.musicLyricsEnableTitle),
              content: Text(locals.musicLyricsEnablePrompt),
              actions: [
                TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(locals.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(locals.musicLyricsEnable)),
              ],
            ));
          },
        );
        if (confirmed != true || !isCurrent()) return;
        await setLrclibEnabled(true, expectedProfileId: profile);
      }
      if (!mounted || !isCurrent() || !isLrclibEnabled()) return;
      final duration = video?.lengthSeconds ?? offline?.lengthSeconds;
      final consent = lrclibPreferenceRevision.value;
      bool mayLoad() =>
          isCurrent() &&
          isLrclibEnabled() &&
          lrclibPreferenceRevision.value == consent;
      final loader = widget.loader;
      await showSafeModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => FractionallySizedBox(
          widthFactor: 1,
          heightFactor: 0.85,
          child: PlayerModalBackHandler(
              child: ValueListenableBuilder<int>(
            valueListenable: lrclibPreferenceRevision,
            builder: (context, revision, _) => revision != consent
                ? Center(
                    child: Text(
                        AppLocalizations.of(context)!.musicLyricsUnavailable))
                : _MusicLyricsSheet(
                    songTitle: track.title,
                    load: () => loader(track, duration, videoId),
                    isCurrent: mayLoad),
          )),
        ),
      );
    } catch (_) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.musicLyricsLoadFailed)));
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
        key: const ValueKey('music-player-lyrics'),
        onPressed: _open,
        icon: const Icon(Icons.lyrics_outlined, size: 20),
        label: Text(AppLocalizations.of(context)!.musicLyrics),
      );
}

class _MusicLyricsSheet extends StatefulWidget {
  final String songTitle;
  final Future<MusicLyrics> Function() load;
  final bool Function() isCurrent;

  const _MusicLyricsSheet(
      {required this.songTitle, required this.load, required this.isCurrent});

  @override
  State<_MusicLyricsSheet> createState() => _MusicLyricsSheetState();
}

class _MusicLyricsSheetState extends State<_MusicLyricsSheet> {
  late Future<MusicLyrics> _request = _load();

  Future<MusicLyrics> _load() async {
    if (!widget.isCurrent()) return const MusicLyrics.unavailable();
    final lyrics = await widget.load();
    return mounted && widget.isCurrent()
        ? lyrics
        : const MusicLyrics.unavailable();
  }

  Duration? _seekLimit(PlayerState state) {
    final seconds = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds;
    return state.currentlyPlaying?.liveNow != true &&
            seconds != null &&
            seconds > 0
        ? Duration(seconds: seconds)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final currentTrack =
        context.select((PlayerCubit player) => widget.isCurrent());
    final currentSession = context.select((AppCubit app) => widget.isCurrent());
    final seekLimit =
        context.select((PlayerCubit player) => _seekLimit(player.state));
    if (!currentTrack || !currentSession) {
      return Center(child: Text(locals.musicLyricsUnavailable));
    }
    return FutureBuilder<MusicLyrics>(
      future: _request,
      builder: (context, snapshot) {
        if (!widget.isCurrent()) {
          return Center(child: Text(locals.musicLyricsUnavailable));
        }
        final lyrics = snapshot.data;
        Widget body;
        if (snapshot.connectionState != ConnectionState.done) {
          body = const Center(
              child:
                  MotionLoadingIndicator(child: CircularProgressIndicator()));
        } else if (snapshot.hasError) {
          body = Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.musicLyricsLoadFailed),
            TextButton(
                onPressed: () {
                  if (!widget.isCurrent()) return;
                  final nextRequest = _load();
                  setState(() {
                    _request = nextRequest;
                  });
                },
                child: Text(locals.retry)),
          ]));
        } else {
          final result = snapshot.requireData;
          body = switch (result.kind) {
            MusicLyricsKind.synced => seekLimit != null &&
                    result.cues.isNotEmpty &&
                    result.cues.last.start <= seekLimit
                ? _timedLines(result.cues)
                : _plainLines(result.cues),
            MusicLyricsKind.plain => result.text == null
                ? _plainLines(result.cues)
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    children: [SelectableText(result.text!)]),
            MusicLyricsKind.instrumental =>
              Center(child: Text(locals.musicLyricsInstrumental)),
            MusicLyricsKind.unavailable =>
              Center(child: Text(locals.musicLyricsUnavailable)),
          };
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(locals.musicLyrics,
                style: Theme.of(context).textTheme.titleLarge),
            Text(widget.songTitle,
                maxLines: 2, overflow: TextOverflow.ellipsis),
            if (lyrics?.source case final source?)
              Text(source, style: Theme.of(context).textTheme.labelMedium),
            const Divider(),
            Expanded(child: body),
          ]),
        );
      },
    );
  }

  Widget _plainLines(List<MusicLyricCue> cues) => ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: cues.length,
        itemBuilder: (context, index) => SelectableText(cues[index].text),
      );

  Widget _timedLines(List<MusicLyricCue> cues) => ListView.builder(
        key: const ValueKey('music-lyrics-lines'),
        itemCount: cues.length,
        itemBuilder: (context, index) {
          final cue = cues[index];
          var next = index + 1;
          while (next < cues.length && cues[next].start == cue.start) {
            next++;
          }
          final end = next < cues.length ? cues[next].start : null;
          return BlocSelector<PlayerCubit, PlayerState, bool>(
            selector: (state) =>
                state.position >= cue.start &&
                (end == null || state.position < end),
            builder: (context, active) => ListTile(
              selected: active,
              leading: Text(prettyDurationCustom(cue.start)),
              title: Text(cue.text),
              onTap: () {
                final player = context.read<PlayerCubit>();
                final limit = _seekLimit(player.state);
                if (widget.isCurrent() && limit != null && cue.start <= limit) {
                  player.seek(cue.start);
                }
              },
            ),
          );
        },
      );
}
