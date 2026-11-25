import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart' show db;
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/services/lrc_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_corrections.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/player/models/local_music_playback.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_lyrics_reader.dart';

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
    final local = isLocalMusicPlaybackId(videoId);
    final library = LocalMusicLibrary.instance;
    final indexedTrack = localMusicTrackForPlayback(videoId);
    final localTrack = indexedTrack != null &&
            !indexedTrack.isCueTrack &&
            indexedTrack.uri == offline?.storageUri
        ? indexedTrack
        : null;
    final localSelection = library.selectionId;
    final localRoot =
        localTrack == null ? null : library.approvedRootForTrack(localTrack);

    bool hasSameLocalGrant() {
      if (localTrack == null || localRoot == null) return true;
      final currentTrack = localMusicTrackForPlayback(videoId);
      if (currentTrack == null ||
          currentTrack.playbackId != localTrack.playbackId ||
          currentTrack.uri != localTrack.uri) {
        return false;
      }
      final currentRoot = library.approvedRootForTrack(currentTrack);
      return library.acceptsSessionSelection(localSelection) &&
          currentRoot != null &&
          currentRoot.uri == localRoot.uri &&
          currentRoot.selectionId == localRoot.selectionId;
    }

    bool isCurrent() {
      final current = player.state;
      return !player.isClosed &&
          !app.isClosed &&
          identical(db, database) &&
          database.profileId == profile &&
          session.profileId == profile &&
          !app.state.globalLoading &&
          !app.state.sessionRecoveryRequired &&
          app.state.sessionRevision == session.sessionRevision &&
          app.state.profileId == session.profileId &&
          player.backendPlaybackGeneration == generation &&
          player.openingMusicEntry == null &&
          current.isAudio &&
          !current.isClosing &&
          !current.isHidden &&
          current.currentQueueId == state.currentQueueId &&
          current.currentlyPlaying?.videoId == video?.videoId &&
          current.offlineCurrentlyPlaying?.videoId == offline?.videoId &&
          (!local ||
              (current.offlineCurrentlyPlaying?.storageUri ==
                      offline?.storageUri &&
                  hasSameLocalGrant()));
    }

    if (!isCurrent()) return;
    _opening = true;
    try {
      if (!local && !isLrclibEnabled()) {
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
        if (confirmed != true || !mounted || !isCurrent()) return;
        await setLrclibEnabled(true, expectedProfileId: profile);
      }
      if (!mounted || !isCurrent() || (!local && !isLrclibEnabled())) return;
      final duration = video?.lengthSeconds ?? offline?.lengthSeconds;
      final consent = lrclibPreferenceRevision.value;
      final loader = widget.loader;
      final localDuration = localTrack != null && localTrack.durationMs > 0
          ? Duration(milliseconds: localTrack.durationMs)
          : null;
      final owner = database.forProfile(profile);
      final correctionTarget = local
          ? null
          : (
              track: track,
              durationSeconds: duration,
              videoId: videoId,
              corrections: MusicLyricsCorrections(owner),
            );
      bool mayRead() =>
          isCurrent() &&
          (local ||
              (isLrclibEnabled() && lrclibPreferenceRevision.value == consent));
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
          child: ListenableBuilder(
            listenable: local ? library : lrclibPreferenceRevision,
            builder: (context, _) => MusicLyricsReader(
              track: track,
              load: local
                  ? () => _loadLocalLyrics(
                      localRoot == null ? null : localTrack,
                      localDuration,
                      AppLocalizations.of(context)!)
                  : () => loader(track, duration, videoId),
              isCurrent: mayRead,
              preferencesDatabase: owner,
              localDuration: localDuration,
              correctionTarget: correctionTarget,
            ),
          ),
        )),
      ));
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

  Future<MusicLyrics> _loadLocalLyrics(LocalMusicTrack? track,
      Duration? duration, AppLocalizations locals) async {
    if (track == null) return const MusicLyrics.unavailable();
    final lyrics = await LocalMusicLibrary.instance.readTrackLyrics(track);
    for (final (text, source) in [
      (lyrics?.sidecar, locals.musicLyricsSidecarSource),
      (lyrics?.embedded, locals.musicLyricsEmbeddedSource),
    ]) {
      final parsed = parseLocalLrc(text);
      final cues = parsed.cues;
      if (duration != null && cues.isNotEmpty && cues.last.start <= duration) {
        return MusicLyrics.synced(cues, source: source);
      }
      if (parsed.plain.isNotEmpty) {
        return MusicLyrics.plain(parsed.plain, source: source);
      }
    }
    return const MusicLyrics.unavailable();
  }

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
        key: const ValueKey('music-player-lyrics'),
        onPressed: _open,
        icon: const Icon(Icons.lyrics_outlined, size: 20),
        label: Text(AppLocalizations.of(context)!.musicLyrics),
      );
}
