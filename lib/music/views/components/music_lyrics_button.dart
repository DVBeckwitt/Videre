import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
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
    if (track == null || videoId == null || isLocalMusicPlaybackId(videoId)) {
      return;
    }

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

  Widget _timedLines(List<MusicLyricCue> cues) => _TimedLyrics(
        cues: cues,
        onSeek: (start) {
          final player = context.read<PlayerCubit>();
          final limit = _seekLimit(player.state);
          if (widget.isCurrent() && limit != null && start <= limit) {
            player.seek(start);
          }
        },
      );
}

class _TimedLyrics extends StatefulWidget {
  final List<MusicLyricCue> cues;
  final ValueChanged<Duration> onSeek;

  const _TimedLyrics({required this.cues, required this.onSeek});

  @override
  State<_TimedLyrics> createState() => _TimedLyricsState();
}

class _TimedLyricsState extends State<_TimedLyrics> {
  static const _center = ValueKey('music-lyrics-current-section');
  static const _alignment = 0.32;
  final _lineKeys = <int, GlobalKey>{};
  late int _anchor;
  int? _lastFollowed;
  bool _following = true;

  @override
  void initState() {
    super.initState();
    final active = _activeLine(context.read<PlayerCubit>().state.position);
    _anchor = active < 0 ? 0 : active;
  }

  int _activeLine(Duration position) {
    final cues = widget.cues;
    var start = 0;
    var end = cues.length;
    while (start < end) {
      final middle = (start + end) ~/ 2;
      if (cues[middle].start <= position) {
        start = middle + 1;
      } else {
        end = middle;
      }
    }
    if (start == 0) return -1;
    final cueStart = cues[start - 1].start;
    end = start - 1;
    start = 0;
    while (start < end) {
      final middle = (start + end) ~/ 2;
      if (cues[middle].start < cueStart) {
        start = middle + 1;
      } else {
        end = middle;
      }
    }
    return start;
  }

  void _reveal(int active, {bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_following || _lastFollowed != active) return;
      final target = active < 0 ? 0 : active;
      final row = _lineKeys[target]?.currentContext;
      if (row != null) {
        Scrollable.ensureVisible(row,
            alignment: _alignment,
            duration: animate ? AppMotion.duration(row) : Duration.zero,
            curve: Curves.easeInOut);
      } else if (_anchor != target) {
        // A seek can land far outside the lazy viewport. Center a new
        // viewport on that cue without laying out the intervening rows.
        setState(() {
          _anchor = target;
          _lastFollowed = null;
        });
      }
    });
  }

  void _pauseFollowing() {
    if (_following) setState(() => _following = false);
  }

  Widget _line(BuildContext context, int index, Duration? activeStart) {
    final cue = widget.cues[index];
    final active = cue.start == activeStart;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return IndexedSemantics(
      index: index,
      child: ListTile(
        key: _lineKeys.putIfAbsent(index, GlobalKey.new),
        selected: active,
        selectedColor: colors.onSecondaryContainer,
        selectedTileColor: colors.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: active
            ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)
            : null,
        leading: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: AppMotion.fadeDuration(
                context, const Duration(milliseconds: 180)),
            width: 4,
            height: 24,
            decoration: BoxDecoration(
                color: active ? colors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 8),
          Text(prettyDurationCustom(cue.start)),
        ]),
        title: Text(cue.text),
        onFocusChange: (focused) {
          if (focused) _pauseFollowing();
        },
        onTap: () => widget.onSeek(cue.start),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = context
        .select((PlayerCubit player) => _activeLine(player.state.position));
    final activeStart = active < 0 ? null : widget.cues[active].start;
    if (_following && _lastFollowed != active) {
      final animate = _lastFollowed != null;
      _lastFollowed = active;
      _reveal(active, animate: animate);
    }
    return Column(children: [
      Expanded(
        child: NotificationListener<UserScrollNotification>(
          onNotification: (notice) {
            if (notice.depth == 0 && notice.direction != ScrollDirection.idle) {
              _pauseFollowing();
            }
            return false;
          },
          child: KeyedSubtree(
            key: const ValueKey('music-lyrics-lines'),
            child: CustomScrollView(
              key: ValueKey(_anchor),
              primary: false,
              center: _center,
              semanticChildCount: widget.cues.length,
              slivers: [
                if (_anchor > 0)
                  SliverList.builder(
                    addSemanticIndexes: false,
                    itemCount: _anchor,
                    itemBuilder: (context, index) =>
                        _line(context, _anchor - index - 1, activeStart),
                  ),
                SliverList.builder(
                  key: _center,
                  addSemanticIndexes: false,
                  itemCount: widget.cues.length - _anchor,
                  itemBuilder: (context, index) =>
                      _line(context, _anchor + index, activeStart),
                ),
              ],
            ),
          ),
        ),
      ),
      Align(
        alignment: AlignmentDirectional.centerEnd,
        child: FilterChip(
          label: Text(AppLocalizations.of(context)!.musicFollowLyrics),
          selected: _following,
          onSelected: (following) => setState(() {
            _following = following;
            _lastFollowed = null;
          }),
        ),
      ),
    ]);
  }
}
