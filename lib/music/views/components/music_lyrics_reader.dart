import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
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
import 'music_lyrics_keep_awake.dart';
import 'music_lyrics_match_dialog.dart';
import 'music_timed_lyrics.dart';

typedef MusicLyricsCorrectionTarget = ({
  MusicMetadata track,
  int? durationSeconds,
  String videoId,
  MusicLyricsCorrections corrections,
});

class MusicLyricsReader extends StatefulWidget {
  final MusicMetadata track;
  final Future<MusicLyrics> Function() load;
  final bool Function() isCurrent;
  final IDbClient preferencesDatabase;
  final Duration? localDuration;
  final MusicLyricsCorrectionTarget? correctionTarget;

  const MusicLyricsReader({
    super.key,
    required this.track,
    required this.load,
    required this.isCurrent,
    required this.preferencesDatabase,
    this.localDuration,
    this.correctionTarget,
  });

  @override
  State<MusicLyricsReader> createState() => _MusicLyricsReaderState();
}

class _MusicLyricsReaderState extends State<MusicLyricsReader> {
  MusicLyricsCorrection? _correction;
  late Future<MusicLyrics> _request = _load();
  late MusicLyricsReaderPreferences _preferences =
      MusicLyricsReaderPreferences.forDatabase(widget.preferencesDatabase);
  bool _savingAppearance = false;

  Future<MusicLyrics> _load() async {
    if (!widget.isCurrent()) return const MusicLyrics.unavailable();
    final target = widget.correctionTarget;
    _correction = target?.corrections.read(target.videoId);
    final lyrics = _correction?.lyrics ?? await widget.load();
    return mounted && widget.isCurrent()
        ? lyrics
        : const MusicLyrics.unavailable();
  }

  void _reload() {
    if (!widget.isCurrent()) return;
    final request = _load();
    setState(() {
      _request = request;
    });
  }

  Duration? _seekLimit(PlayerCubit player) {
    final state = player.state;
    if (player.openingMusicEntry != null ||
        state.currentlyPlaying?.liveNow == true) {
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
      _ => previous,
    };
    if (next.size == previous.size && next.alignment == previous.alignment) {
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

  Widget _appearanceMenu(AppLocalizations locals) {
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
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      itemCount: lyrics.text != null ? 1 : lyrics.cues.length,
      itemBuilder: (context, index) => SelectableText(
        lyrics.text ?? lyrics.cues[index].text,
        style: style,
        textAlign: alignment,
      ),
    );
  }

  Widget _page(AppLocalizations locals,
      {required Widget body,
      MusicLyrics? lyrics,
      bool hasText = false,
      bool ready = false}) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const ValueKey('music-lyrics-reader'),
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(locals.musicLyrics),
        backgroundColor: theme.colorScheme.surface,
        actions: [
          if (ready && widget.correctionTarget != null)
            IconButton(
              tooltip: locals.musicLyricsCorrectMatch,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _correct(lyrics),
            ),
          if (hasText) _appearanceMenu(locals),
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
                const Divider(height: 1),
                Expanded(
                  child: hasText ? MusicLyricsKeepAwake(child: body) : body,
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

    return PlayerModalBackHandler(
      child: !currentTrack || !currentSession
          ? _page(locals, body: unavailable)
          : FutureBuilder<MusicLyrics>(
              future: _request,
              builder: (context, snapshot) {
                if (!widget.isCurrent()) {
                  return _page(locals, body: unavailable);
                }
                if (snapshot.connectionState != ConnectionState.done) {
                  return _page(locals,
                      body: const Center(
                          child: MotionLoadingIndicator(
                              child: CircularProgressIndicator())));
                }
                if (snapshot.hasError) {
                  return _page(locals,
                      ready: true,
                      body: Center(
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(locals.musicLyricsLoadFailed),
                        TextButton(
                          onPressed: _reload,
                          child: Text(locals.retry),
                        ),
                      ])));
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
                      track: widget.track,
                      edited: _correction?.edited == true,
                      preferences: _preferences,
                      seekLimit: seekLimit,
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
                return _page(locals,
                    body: body, lyrics: lyrics, hasText: hasText, ready: true);
              },
            ),
    );
  }
}
