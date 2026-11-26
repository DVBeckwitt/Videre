import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/models/local_music_playback.dart';
import '../../../player/states/player.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../utils/interfaces/db.dart';
import '../../../utils/motion.dart';
import '../../../videos/models/music_metadata.dart';
import '../../models/music_lyrics.dart';
import '../../models/music_lyrics_match.dart';
import '../../services/music_lyrics_corrections.dart';
import '../../services/music_lyrics_preferences.dart';
import '../../services/music_lyrics_reader_preferences.dart';
import '../../services/music_lyrics_service.dart';
import '../../services/music_offline_lyrics.dart';
import 'music_lyrics_keep_awake.dart';
import 'music_lyrics_match_dialog.dart';
import 'music_lyric_cue_details.dart';
import 'music_timed_lyrics.dart';

typedef MusicLyricsCorrectionTarget = ({
  MusicMetadata track,
  int? durationSeconds,
  String videoId,
  MusicLyricsCorrections corrections,
});

enum _AppearanceToggle { multiline, trim }

class MusicLyricsReader extends StatefulWidget {
  final MusicMetadata track;
  final String recordingId;
  final bool inline;
  final Future<MusicLyrics> Function(Future<void> retired) load;
  final bool Function() isCurrent;
  final IDbClient preferencesDatabase;
  final Duration? localDuration;
  final MusicLyricsCorrectionTarget? correctionTarget;
  final MusicOfflineLyrics? offlineLyrics;
  final void Function(MusicLyrics? lyrics, Duration delay)? onResolved;
  final Widget Function(MusicLyrics lyrics, VoidCallback reload)?
      localEditAction;
  final Future<List<File>> Function()? loadShareArtwork;

  const MusicLyricsReader({
    super.key,
    required this.track,
    required this.recordingId,
    required this.load,
    required this.isCurrent,
    required this.preferencesDatabase,
    this.inline = false,
    this.localDuration,
    this.correctionTarget,
    this.offlineLyrics,
    this.onResolved,
    this.localEditAction,
    this.loadShareArtwork,
  });

  @override
  State<MusicLyricsReader> createState() => _MusicLyricsReaderState();
}

class _MusicLyricsReaderState extends State<MusicLyricsReader> {
  final _retired = Completer<void>();
  MusicLyricsCorrection? _correction;
  bool _savedOffline = false;
  bool _updatingOffline = false;
  bool _offlineUpdateFailed = false;
  MusicLyrics? _resolvedLyrics;
  int _loadRevision = 0;
  late Future<MusicLyrics> _request = _load();
  late MusicLyricsReaderPreferences _preferences =
      MusicLyricsReaderPreferences.forDatabase(widget.preferencesDatabase);
  bool _savingAppearance = false;
  late final _timing = MusicLyricsTimingPreference(
      widget.preferencesDatabase, widget.recordingId);
  late int _delayMilliseconds = _timing.read();
  bool _showTimingControls = false;
  bool _savingTiming = false;

  Future<MusicLyrics> _load() async {
    if (!widget.isCurrent()) return const MusicLyrics.unavailable();
    final revision = ++_loadRevision;
    final target = widget.correctionTarget;
    _correction = target?.corrections.read(target.videoId);
    final saved = _correction == null && target != null
        ? widget.offlineLyrics?.read(target.videoId,
            track: target.track, durationSeconds: target.durationSeconds)
        : null;
    _savedOffline = saved != null;
    final stored = _correction?.lyrics ?? saved;
    final lyrics = await (stored == null
        ? widget.load(_retired.future)
        : Future.value(stored));
    if (!mounted || !widget.isCurrent() || revision != _loadRevision) {
      return const MusicLyrics.unavailable();
    }
    _resolvedLyrics = lyrics;
    _publishResolved();
    return lyrics;
  }

  void _publishResolved() {
    widget.onResolved
        ?.call(_resolvedLyrics, Duration(milliseconds: _delayMilliseconds));
  }

  void _reload() {
    if (!widget.isCurrent()) return;
    _resolvedLyrics = null;
    _publishResolved();
    final request = _load();
    setState(() {
      _request = request;
    });
  }

  Future<void> _updateOffline(MusicLyrics lyrics) async {
    final target = widget.correctionTarget;
    final store = widget.offlineLyrics;
    if (!widget.isCurrent() ||
        _updatingOffline ||
        _correction != null ||
        target == null ||
        store == null) {
      return;
    }
    setState(() {
      _updatingOffline = true;
      _offlineUpdateFailed = false;
    });
    final wasSaved = _savedOffline;
    try {
      if (wasSaved) {
        await store.remove(target.videoId);
      } else {
        await store.save(target.videoId, lyrics,
            track: target.track, durationSeconds: target.durationSeconds);
      }
      if (!mounted || !widget.isCurrent()) return;
      if (wasSaved) {
        _reload();
      } else {
        setState(() => _savedOffline = true);
      }
    } catch (_) {
      if (mounted && widget.isCurrent()) {
        setState(() => _offlineUpdateFailed = true);
      }
    } finally {
      if (mounted && widget.isCurrent()) {
        setState(() => _updatingOffline = false);
      }
    }
  }

  @override
  void dispose() {
    _retired.complete();
    super.dispose();
  }

  Duration? _seekLimit(PlayerCubit player) {
    final state = player.state;
    if (player.openingMusicEntry != null ||
        state.currentlyPlaying?.liveNow == true ||
        (isLocalMusicPlaybackId(state.currentQueueId) &&
            !player.canSeekCurrentMedia)) {
      return null;
    }
    if (widget.localDuration case final duration?) return duration;
    final seconds = state.currentlyPlaying?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds;
    return seconds != null && seconds > 0 ? Duration(seconds: seconds) : null;
  }

  Future<void> _correct(MusicLyrics? lyrics) async {
    final target = widget.correctionTarget;
    bool mayCorrect() => mounted && widget.isCurrent();
    if (target == null || !mayCorrect()) return;

    final hasCorrection = _correction != null;
    final app = context.read<AppCubit>();
    final player = context.read<PlayerCubit>();
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: false,
      builder: (routeContext) => PlayerModalBackHandler(
        onBack: () => Navigator.of(routeContext).maybePop(),
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: app),
            BlocProvider.value(value: player),
          ],
          child: ValueListenableBuilder<int>(
            valueListenable: lrclibPreferenceRevision,
            builder: (context, _, __) {
              final currentTrack =
                  context.select((PlayerCubit _) => mayCorrect());
              final currentSession =
                  context.select((AppCubit _) => mayCorrect());
              if (!currentTrack || !currentSession) {
                final locals = AppLocalizations.of(context)!;
                return AlertDialog(
                  content: Text(locals.musicLyricsUnavailable),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(locals.cancel)),
                  ],
                );
              }
              return MusicLyricsMatchDialog(
                track: target.track,
                durationSeconds: target.durationSeconds,
                currentLyrics: lyrics,
                hasCorrection: hasCorrection,
                isCurrent: mayCorrect,
                search: searchMusicLyrics,
                save: (correction) async {
                  if (!mayCorrect()) return;
                  if (correction == null) {
                    await target.corrections.clear(target.videoId);
                  } else {
                    await target.corrections.save(target.videoId, correction);
                  }
                },
              );
            },
          ),
        ),
      ),
    );
    if (saved == true && mounted) _reload();
  }

  void _seek(Duration position) {
    final player = context.read<PlayerCubit>();
    final limit = _seekLimit(player);
    if (widget.isCurrent() &&
        ModalRoute.isCurrentOf(context) == true &&
        limit != null &&
        position >= Duration.zero &&
        position <= limit) {
      player.seek(position);
    }
  }

  Future<void> _changeAppearance(Object choice) async {
    if (_savingAppearance || !widget.isCurrent()) return;
    final previous = _preferences;
    final next = switch (choice) {
      final MusicLyricsTextSize size => previous.copyWith(size: size),
      final MusicLyricsTextAlignment alignment =>
        previous.copyWith(alignment: alignment),
      _AppearanceToggle.multiline =>
        previous.copyWith(multiline: !previous.multiline),
      _AppearanceToggle.trim => previous.copyWith(trim: !previous.trim),
      _ => previous,
    };
    if (next.size == previous.size &&
        next.alignment == previous.alignment &&
        next.multiline == previous.multiline &&
        next.trim == previous.trim) {
      return;
    }
    setState(() {
      _preferences = next;
      _savingAppearance = true;
    });
    try {
      await next.save(widget.preferencesDatabase);
    } catch (_) {
      if (!mounted) return;
      setState(() => _preferences = previous);
      if (widget.isCurrent()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!
                .musicLyricsAppearanceSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _savingAppearance = false);
    }
  }

  Widget _appearanceMenu(AppLocalizations locals, {required bool synced}) {
    return PopupMenuButton<Object>(
      key: const ValueKey('music-lyrics-appearance'),
      tooltip: locals.musicLyricsAppearance,
      enabled: !_savingAppearance,
      icon: const Icon(Icons.text_fields),
      onSelected: _changeAppearance,
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: Text(locals.musicLyricsTextSize),
        ),
        for (final (size, label) in [
          (MusicLyricsTextSize.small, locals.musicLyricsTextSmall),
          (MusicLyricsTextSize.medium, locals.musicLyricsTextMedium),
          (MusicLyricsTextSize.large, locals.musicLyricsTextLarge),
        ])
          CheckedPopupMenuItem<Object>(
            value: size,
            checked: _preferences.size == size,
            child: Text(label),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          enabled: false,
          child: Text(locals.musicLyricsTextAlignment),
        ),
        for (final (alignment, label) in [
          (MusicLyricsTextAlignment.start, locals.musicLyricsAlignStart),
          (MusicLyricsTextAlignment.center, locals.musicLyricsAlignCenter),
        ])
          CheckedPopupMenuItem<Object>(
            value: alignment,
            checked: _preferences.alignment == alignment,
            child: Text(label),
          ),
        if (synced) ...[
          const PopupMenuDivider(),
          CheckedPopupMenuItem<Object>(
            value: _AppearanceToggle.multiline,
            checked: _preferences.multiline,
            child: Text(locals.musicLyricsMultiline),
          ),
          CheckedPopupMenuItem<Object>(
            value: _AppearanceToggle.trim,
            checked: _preferences.trim,
            child: Text(locals.musicLyricsTrim),
          ),
        ],
      ],
    );
  }

  Future<void> _changeTiming(int milliseconds) async {
    if (_savingTiming ||
        !widget.isCurrent() ||
        ModalRoute.isCurrentOf(context) != true) {
      return;
    }
    setState(() => _savingTiming = true);
    try {
      await _timing.save(milliseconds);
      if (mounted && widget.isCurrent()) {
        setState(() => _delayMilliseconds = milliseconds);
        _publishResolved();
      }
    } catch (_) {
      if (mounted && widget.isCurrent()) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context)!.musicLyricsTimingSaveFailed),
        ));
      }
    } finally {
      if (mounted) setState(() => _savingTiming = false);
    }
  }

  Widget _timingControls(AppLocalizations locals) {
    final delay = _delayMilliseconds;
    const step = MusicLyricsTimingPreference.stepMilliseconds;
    const limit = MusicLyricsTimingPreference.limitMilliseconds;
    final signedDelay = delay > 0 ? '+$delay' : '$delay';
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        TextButton(
          onPressed: _savingTiming || delay <= -limit
              ? null
              : () => _changeTiming((delay - step).clamp(-limit, limit)),
          child: Text(locals.musicLyricsTimingEarlier),
        ),
        Text(locals.musicLyricsTimingValue(signedDelay)),
        TextButton(
          onPressed: _savingTiming || delay >= limit
              ? null
              : () => _changeTiming((delay + step).clamp(-limit, limit)),
          child: Text(locals.musicLyricsTimingLater),
        ),
        TextButton(
          onPressed:
              _savingTiming || delay == 0 ? null : () => _changeTiming(0),
          child: Text(locals.musicLyricsTimingReset),
        ),
      ],
    );
  }

  Widget _plainLyrics(MusicLyrics lyrics) {
    final style = Theme.of(context)
        .textTheme
        .bodyLarge
        ?.copyWith(fontSize: _preferences.size.fontSize, height: 1.5);
    final alignment = _preferences.alignment == MusicLyricsTextAlignment.center
        ? TextAlign.center
        : TextAlign.start;
    return ListView.builder(
      primary: widget.inline ? false : null,
      padding: widget.inline
          ? const EdgeInsets.all(8)
          : const EdgeInsets.fromLTRB(24, 16, 24, 32),
      itemCount: lyrics.text != null ? 1 : lyrics.cues.length,
      itemBuilder: (context, index) {
        final child = SelectableText(
          lyrics.text ??
              (lyrics.kind == MusicLyricsKind.synced
                  ? _preferences.syncedCueText(lyrics, index)
                  : lyrics.cues[index].text),
          style: style,
          textAlign: alignment,
        );
        final metadata = lyrics.metadataByCue[index];
        return metadata != null && metadata.hasDetails
            ? Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: MusicLyricCueDetails(
                    metadata: metadata, alignment: alignment, child: child),
              )
            : child;
      },
    );
  }

  Widget _present(AppLocalizations locals,
      {required Widget body,
      MusicLyrics? lyrics,
      bool hasText = false,
      bool ready = false,
      bool hasTiming = false}) {
    if (widget.inline) {
      if (hasText) return body;
      return Center(
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.all(8),
          child: body,
        ),
      );
    }
    final theme = Theme.of(context);
    return Scaffold(
      key: const ValueKey('music-lyrics-reader'),
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(locals.musicLyrics),
        backgroundColor: theme.colorScheme.surface,
        actions: [
          if (widget.localEditAction case final edit? when ready)
            edit(lyrics ?? const MusicLyrics.unavailable(), _reload),
          if (ready && widget.correctionTarget != null)
            IconButton(
              tooltip: locals.musicLyricsCorrectMatch,
              icon: const Icon(Icons.edit_outlined),
              onPressed: _updatingOffline ? null : () => _correct(lyrics),
            ),
          if (hasTiming)
            IconButton(
              key: const ValueKey('music-lyrics-timing'),
              tooltip: locals.musicLyricsTiming,
              isSelected: _showTimingControls,
              icon: const Icon(Icons.timer_outlined),
              selectedIcon: const Icon(Icons.timer),
              onPressed: () =>
                  setState(() => _showTimingControls = !_showTimingControls),
            ),
          if (hasText)
            _appearanceMenu(locals,
                synced: lyrics?.kind == MusicLyricsKind.synced),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(24, 8, 24, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium),
                      if (lyrics?.source case final source?)
                        Text(source, style: theme.textTheme.labelMedium),
                      if (ready && _correction?.edited == true)
                        Text(locals.musicLyricsEdited,
                            style: theme.textTheme.labelMedium),
                    ],
                  ),
                ),
                if (hasTiming && _showTimingControls) _timingControls(locals),
                const Divider(height: 1),
                Expanded(
                  child: hasText ? MusicLyricsKeepAwake(child: body) : body,
                ),
                if (_offlineUpdateFailed)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(locals.musicLyricsOfflineSaveFailed,
                        style: TextStyle(color: theme.colorScheme.error)),
                  ),
                if (ready &&
                    widget.offlineLyrics != null &&
                    _correction == null &&
                    lyrics != null &&
                    lyrics.kind != MusicLyricsKind.unavailable)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        onPressed: _updatingOffline
                            ? null
                            : () => _updateOffline(lyrics),
                        icon: Icon(_savedOffline
                            ? Icons.download_done_outlined
                            : Icons.download_outlined),
                        label: Text(_savedOffline
                            ? locals.musicLyricsRemoveOffline
                            : locals.musicLyricsSaveOffline),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final (currentTrack, seekLimit) = context.select(
        (PlayerCubit player) => (widget.isCurrent(), _seekLimit(player)));
    final currentSession = context.select((AppCubit _) => widget.isCurrent());
    final unavailable = Center(
        child:
            Text(locals.musicLyricsUnavailable, textAlign: TextAlign.center));

    final content = !currentTrack || !currentSession
        ? _present(locals, body: unavailable)
        : FutureBuilder<MusicLyrics>(
            future: _request,
            builder: (context, snapshot) {
              if (!widget.isCurrent()) {
                return _present(locals, body: unavailable);
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return _present(locals,
                    body: const Center(
                        child: MotionLoadingIndicator(
                            child: CircularProgressIndicator())));
              }
              if (snapshot.hasError) {
                final retry = Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(locals.musicLyricsLoadFailed,
                      textAlign: TextAlign.center),
                  TextButton(
                    onPressed: _reload,
                    child: Text(locals.retry),
                  ),
                ]);
                return _present(locals,
                    ready: true, body: Center(child: retry));
              }
              final lyrics = snapshot.requireData;
              final hasText = switch (lyrics.kind) {
                MusicLyricsKind.synced ||
                MusicLyricsKind.plain =>
                  lyrics.cues.isNotEmpty ||
                      lyrics.text?.trim().isNotEmpty == true,
                _ => false,
              };
              final body = switch (lyrics.kind) {
                MusicLyricsKind.synced
                    when seekLimit != null &&
                        lyrics.cues.isNotEmpty &&
                        lyrics.cues.last.start <= seekLimit =>
                  MusicTimedLyrics(
                    lyrics: lyrics,
                    inline: widget.inline,
                    track: widget.track,
                    edited: _correction?.edited == true,
                    preferences: _preferences,
                    loadShareArtwork: widget.loadShareArtwork,
                    seekLimit: seekLimit,
                    delay: Duration(milliseconds: _delayMilliseconds),
                    isCurrent: widget.isCurrent,
                    onSeek: _seek,
                  ),
                MusicLyricsKind.synced ||
                MusicLyricsKind.plain =>
                  hasText ? _plainLyrics(lyrics) : unavailable,
                MusicLyricsKind.instrumental =>
                  Center(child: Text(locals.musicLyricsInstrumental)),
                MusicLyricsKind.unavailable => _correction == null
                    ? unavailable
                    : Center(child: Text(locals.musicLyricsMatchDiscarded)),
              };
              return _present(locals,
                  body: body,
                  lyrics: lyrics,
                  hasText: hasText,
                  ready: true,
                  hasTiming: body is MusicTimedLyrics);
            },
          );
    return widget.inline ? content : PlayerModalBackHandler(child: content);
  }
}
