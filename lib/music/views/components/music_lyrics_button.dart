import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/local_music_lyrics_authoring.dart';
import 'package:clipious/music/services/local_music_timed_lyrics.dart';
import 'package:clipious/music/services/lrc_lyrics.dart';
import 'package:clipious/music/services/music_lyric_share_artwork.dart';
import 'package:clipious/music/services/music_lyrics_corrections.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/music/services/music_lyrics_service.dart';
import 'package:clipious/music/services/music_offline_lyrics.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_local_lyrics_edit_button.dart';
import 'music_lyrics_reader.dart';

class MusicLyricsButton extends StatefulWidget {
  final MusicLyricsLoader? loader;
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
    final initial = _activeSong(player);
    if (initial == null) return;
    final local = isLocalMusicPlaybackId(initial.videoId);

    bool ownsSession() =>
        !player.isClosed &&
        !app.isClosed &&
        identical(db, database) &&
        database.profileId == profile &&
        app.state.profileId == profile &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired &&
        app.state.sessionRevision == session.sessionRevision;

    bool stillOpening() =>
        mounted && ownsSession() && _activeSong(player) == initial;

    if (!ownsSession()) return;
    _opening = true;
    try {
      final owner = database.forProfile(profile);
      final offlineLyrics = MusicOfflineLyrics(owner);
      final corrections = MusicLyricsCorrections(owner);
      if (!local &&
          !isLrclibEnabled() &&
          corrections.read(initial.videoId) == null &&
          offlineLyrics.read(initial.videoId,
                  track: _musicMetadata(player.state)!,
                  durationSeconds: initial.durationSeconds) ==
              null) {
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
        if (confirmed != true || !stillOpening()) return;
        await setLrclibEnabled(true, expectedProfileId: profile);
      }
      if (!mounted || !stillOpening()) return;
      final loader = widget.loader;
      final navigator = Navigator.of(context);
      final themes =
          InheritedTheme.capture(from: context, to: navigator.context);
      await navigator.push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => themes.wrap(MultiBlocProvider(
          providers: [
            BlocProvider.value(value: app),
            BlocProvider.value(value: player),
          ],
          child: _FollowingLyricsReader(
            owner: owner,
            loader: loader,
            corrections: corrections,
            offlineLyrics: offlineLyrics,
            ownsSession: ownsSession,
          ),
        )),
      ));
    } catch (_) {
      if (mounted && stillOpening()) {
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

typedef _PlayingLyricsSong = ({
  int generation,
  String? occurrence,
  String videoId,
  int? durationSeconds,
  String? storageUri,
  String title,
  String artist,
  String? album,
});

MusicMetadata? _musicMetadata(PlayerState state) =>
    state.currentlyPlaying?.musicMetadata ??
    state.offlineCurrentlyPlaying?.musicMetadata;

_PlayingLyricsSong? _activeSong(PlayerCubit player) {
  final state = player.state;
  if (!state.isAudio ||
      state.isClosing ||
      state.isHidden ||
      player.openingMusicEntry != null) {
    return null;
  }
  final video = state.currentlyPlaying;
  final offline = state.offlineCurrentlyPlaying;
  final videoId = video?.videoId ?? offline?.videoId;
  final track = _musicMetadata(state);
  if (videoId == null || track == null) return null;
  return (
    generation: player.backendPlaybackGeneration,
    occurrence: state.currentQueueId,
    videoId: videoId,
    durationSeconds: video?.lengthSeconds ?? offline?.lengthSeconds,
    storageUri: offline?.storageUri,
    title: track.title,
    artist: track.artist,
    album: track.album,
  );
}

class _FollowingLyricsReader extends StatelessWidget {
  final IDbClient owner;
  final MusicLyricsLoader? loader;
  final MusicLyricsCorrections corrections;
  final MusicOfflineLyrics offlineLyrics;
  final bool Function() ownsSession;

  const _FollowingLyricsReader({
    required this.owner,
    required this.loader,
    required this.corrections,
    required this.offlineLyrics,
    required this.ownsSession,
  });

  @override
  Widget build(BuildContext context) {
    final currentSession = context.select((AppCubit _) => ownsSession());
    final (song, opening) = context.select((PlayerCubit player) =>
        (_activeSong(player), player.openingMusicEntry != null));
    final locals = AppLocalizations.of(context)!;
    if (!currentSession || song == null) {
      return PlayerModalBackHandler(
        child: Scaffold(
          key: const ValueKey('music-lyrics-reader'),
          appBar: AppBar(title: Text(locals.musicLyrics)),
          body: Center(
            child: currentSession && opening
                ? const MotionLoadingIndicator(
                    child: CircularProgressIndicator())
                : Text(locals.musicLyricsUnavailable,
                    textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final player = context.read<PlayerCubit>();
    final track = _musicMetadata(player.state)!;
    final local = isLocalMusicPlaybackId(song.videoId);
    final video = player.state.currentlyPlaying;
    final offline = player.state.offlineCurrentlyPlaying;
    final server = context.read<AppCubit>().state.server;
    final library = LocalMusicLibrary.instance;
    final Listenable sourceChanges = local ? library : lrclibPreferenceRevision;
    return ListenableBuilder(
      listenable: sourceChanges,
      builder: (context, _) {
        final consent = lrclibPreferenceRevision.value;
        final selection = library.selectionId;
        final indexedTrack = localMusicTrackForPlayback(song.videoId);
        final root = indexedTrack != null && !indexedTrack.isCueTrack
            ? library.approvedRootForTrack(indexedTrack)
            : null;
        final localTrack = local &&
                root != null &&
                indexedTrack != null &&
                indexedTrack.uri == song.storageUri &&
                library.acceptsSessionSelection(selection)
            ? indexedTrack
            : null;
        final localDuration = localTrack != null && localTrack.durationMs > 0
            ? Duration(milliseconds: localTrack.durationMs)
            : null;

        bool sameLocalGrant() {
          if (localTrack == null) return true;
          final currentTrack = localMusicTrackForPlayback(song.videoId);
          if (currentTrack == null ||
              currentTrack.playbackId != localTrack.playbackId ||
              currentTrack.uri != localTrack.uri) {
            return false;
          }
          final currentRoot = library.approvedRootForTrack(currentTrack);
          return library.acceptsSessionSelection(selection) &&
              currentRoot != null &&
              currentRoot.uri == root?.uri &&
              currentRoot.selectionId == root?.selectionId;
        }

        bool isCurrent() =>
            ownsSession() &&
            _activeSong(player) == song &&
            (local
                ? sameLocalGrant()
                : lrclibPreferenceRevision.value == consent);

        final authoring = localTrack == null
            ? null
            : LocalMusicLyricsAuthoring.forTrack(
                database: owner, track: localTrack, isCurrent: isCurrent);
        Future<bool> canReadRecording() async =>
            localTrack != null &&
            isCurrent() &&
            await library.readTrackLyrics(localTrack) != null &&
            isCurrent();

        return MusicLyricsReader(
          key: ValueKey((
            song,
            local ? selection : consent,
            root?.uri,
            root?.selectionId,
            localTrack?.uri,
            localDuration
          )),
          track: track,
          recordingId: local ? localMusicTrackId(song.videoId) : song.videoId,
          load: (retired) {
            if (local) {
              return _loadLocalLyrics(localTrack, localDuration, locals,
                  authoring: authoring);
            }
            if (!isLrclibEnabled()) {
              return Future.value(const MusicLyrics.unavailable());
            }
            return loader?.call(track, song.durationSeconds, song.videoId) ??
                loadMusicLyrics(track, song.durationSeconds, song.videoId,
                    isPlaybackCurrent: isCurrent, retired: retired);
          },
          isCurrent: isCurrent,
          onResolved: (lyrics, delay) => player.publishResolvedMusicLyrics(
              lyrics, delay,
              mayRead: isCurrent, sourceChanges: sourceChanges),
          preferencesDatabase: owner,
          localDuration: localDuration,
          correctionTarget: local
              ? null
              : (
                  track: track,
                  durationSeconds: song.durationSeconds,
                  videoId: song.videoId,
                  corrections: corrections
                ),
          loadShareArtwork: () => findMusicLyricShareArtwork(
            track: track,
            video: video,
            offline: offline,
            localTrack: localTrack,
            server: server,
            owner: owner,
            isCurrent: isCurrent,
          ),
          offlineLyrics: local ? null : offlineLyrics,
          localEditAction: authoring == null
              ? null
              : (lyrics, reload) => MusicLocalLyricsEditButton(
                    authoring: authoring,
                    songTitle: song.title,
                    lyrics: lyrics,
                    canReadRecording: canReadRecording,
                    onChanged: reload,
                  ),
        );
      },
    );
  }
}

Future<MusicLyrics> _loadLocalLyrics(
    LocalMusicTrack? track, Duration? duration, AppLocalizations locals,
    {required LocalMusicLyricsAuthoring? authoring}) async {
  if (track == null) return const MusicLyrics.unavailable();
  final lyrics = await LocalMusicLibrary.instance.readTrackLyrics(track);
  if (lyrics == null) return const MusicLyrics.unavailable();
  final authored = authoring?.load(source: locals.musicLyricsAuthoredSource);
  if (authored != null) return authored;
  if (authoring?.readPlainDraft() case final plain?) {
    return MusicLyrics.plain(plain,
        source: locals.musicLyricsAuthoredPlainSource);
  }
  final timedSidecar = decodeLocalTimedLyrics(
    lyrics.timedSidecar,
    source: locals.musicLyricsSidecarSource,
  );
  if (timedSidecar != null) return timedSidecar;
  for (final (text, source) in [
    (lyrics.sidecar, locals.musicLyricsSidecarSource),
    (lyrics.embedded, locals.musicLyricsEmbeddedSource),
  ]) {
    final parsed = parseLocalLrc(text, playbackDuration: duration);
    final cues = parsed.cues;
    if (duration != null && cues.isNotEmpty && cues.last.start <= duration) {
      return MusicLyrics.synced(cues,
          source: source,
          wordsByCue: parsed.wordsByCue,
          displayTextByCue: parsed.displayTextByCue,
          breakStarts: parsed.breakStarts);
    }
    if (parsed.plain.isNotEmpty) {
      return MusicLyrics.plain(parsed.plain, source: source);
    }
  }
  return const MusicLyrics.unavailable();
}
