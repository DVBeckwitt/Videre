import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

import '../../globals.dart';
import '../../player/states/player.dart';
import '../../settings/models/db/server.dart';
import '../../utils/interfaces/db.dart';
import '../../videos/models/video.dart';
import '../models/playlist.dart';
import '../models/playlist_reference.dart';
import '../services/playlist_load_session.dart';
import '../services/playlist_progress.dart';

part 'playlist.freezed.dart';

class PlaylistPlaybackRequest {
  final List<Video> videos;
  final PlaylistReference reference;
  final PlaylistLoadSession loader;
  final int startIndex;
  final Duration? startAt;
  final bool? audio;

  const PlaylistPlaybackRequest(this.videos, this.reference, this.loader,
      {required this.startIndex, this.startAt, this.audio});
}

class PlaylistCubit extends Cubit<PlaylistState> {
  final ScrollController scrollController = ScrollController();
  final PlayerCubit player;
  final PlaylistReference? bookmarkOwner;
  late final IDbClient _database;
  late final PlaylistLoadSession loader;
  late final StreamSubscription<PlaylistLoadSnapshot> _loading;

  PlaylistCubit(PlaylistState initialState, this.player,
      {PlaylistReference? reference,
      this.bookmarkOwner,
      PlaylistLoadSession? loadSession})
      : super(initialState.copyWith(
            playlist: initialState.playlist.copyWith(
                videos:
                    assignPlaylistEntryIds(initialState.playlist.videos)))) {
    _database = db.forProfile(db.profileId);
    loader = loadSession ??
        PlaylistLoadSession(
            playlist: initialState.playlist,
            database: _database,
            reference: reference);
    _loading = loader.changes.listen((_) => _syncLoader());
    onReady();
  }

  PlaylistReference? get reference => loader.reference;
  bool get canPlayEntries =>
      !isClosed &&
      _database.profileId == db.profileId &&
      loader.hasPlayableSnapshot;
  List<Video> get playableVideos => canPlayEntries
      ? state.playlist.videos
          .where((video) =>
              !video.filtered && !video.filterHide && video.isUpcoming != true)
          .toList()
      : [];

  PlaylistCheckpoint? get checkpoint {
    final source = reference;
    return source == null
        ? null
        : PlaylistProgressService.forProfile(_database, _database.profileId)
            .get(source);
  }

  PlaylistResumeTarget? get resumeTarget {
    if (!canPlayEntries) return null;
    final target = checkpoint?.resolve(state.playlist.videos);
    // A later page may still contain the original item. Do not offer a fallback
    // until the server has supplied the whole current playlist.
    return target?.missing == true && !loader.complete ? null : target;
  }

  Duration get resumePosition {
    final target = resumeTarget;
    return target == null || target.missing || checkpoint?.completed == true
        ? Duration.zero
        : _database
            .getVideoPlaybackProgress(target.video.videoId)
            .resumePosition(durationSeconds: target.video.lengthSeconds);
  }

  void onReady() => loader.retain();

  void _syncLoader() {
    if (isClosed) return;
    // Broadcast delivery may lag behind an awaited refresh. Read the current
    // snapshot so an older queued notification cannot resurrect deleted rows.
    final playlist = loader.playlist;
    final total = playlist.videoCount;
    emit(state.copyWith(
        playlist: playlist,
        loading: loader.loading,
        loadingProgress:
            total > 0 ? (playlist.videos.length / total).clamp(0.0, 1.0) : 0,
        error: loader.error?.toString() ?? ''));
  }

  Future<void> refreshPlaylist({required bool userPlaylist}) async {
    if (!isClosed && userPlaylist) {
      await loader.refresh();
      _syncLoader();
    }
  }

  Future<void> deletePlaylist() async {
    if (isClosed) return;
    final server = await _assertCanMutate(bookmarkDeletion: true);
    await service.deleteUserPlaylist(reference!.playlistId,
        database: _database, serverOverride: server);
  }

  Future<Server?> _assertCanMutate({bool bookmarkDeletion = false}) async {
    await loader.ready;
    final source = bookmarkDeletion ? bookmarkOwner ?? reference : reference;
    if (isClosed ||
        _database.profileId != db.profileId ||
        source == null ||
        source.profileId != _database.profileId ||
        source.playlistId != reference?.playlistId ||
        source.kind == PlaylistSourceKind.public) {
      throw StateError('The playlist is no longer editable');
    }
    if (source.kind == PlaylistSourceKind.account) {
      final captured = source.resolveServer(_database);
      final current = await _database.getCurrentlySelectedServer();
      if (isClosed ||
          db.profileId != _database.profileId ||
          current.accountId != captured?.accountId ||
          Uri.tryParse(current.url)?.origin != source.origin) {
        throw StateError('The playlist account has changed');
      }
      return captured;
    }
    return null;
  }

  Future<void> removeVideoFromPlayList(Video video) async {
    if (isClosed) return;
    final server = await _assertCanMutate();
    emit(state.copyWith(loading: true));
    try {
      await service.deleteUserPlaylistVideo(reference!.playlistId,
          state.playlist.isLocal ? video.videoId : video.indexId ?? '',
          database: _database, serverOverride: server);
      if (isClosed) return;
      // Replace the loader's snapshot as well as the visible state. This also
      // invalidates any page that was already in flight before the deletion.
      await loader.refresh();
    } finally {
      _syncLoader();
    }
  }

  Future<PlaylistPlaybackRequest?> playbackRequest(
      {Video? video,
      bool resume = false,
      bool acceptMissing = false,
      bool fromBeginning = false,
      bool? audio}) async {
    await loader.ready;
    if (!canPlayEntries) return null;
    final source = reference;
    if (source == null) return null;
    var entries = state.playlist.videos;
    final target = resume ? resumeTarget : null;
    if (resume && (target == null || (target.missing && !acceptMissing))) {
      return null;
    }
    final selected = target?.video ?? video ?? playableVideos.firstOrNull;
    if (selected == null ||
        selected.filtered ||
        selected.filterHide ||
        selected.isUpcoming == true) {
      return null;
    }
    final index = entries.indexWhere((entry) =>
        entry.videoId == selected.videoId &&
        ((selected.queueEntryId != null &&
                entry.queueEntryId == selected.queueEntryId) ||
            identical(entry, selected)));
    if (index < 0) return null;
    final original = entries[index];
    if (original.filterHide || original.isUpcoming == true) return null;
    // Revealing a filtered row is an explicit choice for this occurrence only.
    // Keep the source metadata and all other entries' filter decisions intact.
    if (original.filtered) {
      if (video == null || video.filtered) return null;
      entries = [...entries];
      entries[index] = original.copyWith(filtered: false);
    }
    return PlaylistPlaybackRequest(entries, source, loader,
        startIndex: index,
        startAt: resume
            ? resumePosition
            : fromBeginning
                ? Duration.zero
                : null,
        audio: audio ?? (resume ? checkpoint?.audio : null));
  }

  Future<void> _play(PlaylistPlaybackRequest? request) async {
    if (request == null) return;
    await player.playPlaylist(request.videos,
        reference: request.reference,
        startIndex: request.startIndex,
        startAt: request.startAt,
        audio: request.audio,
        playlistLoader: request.loader);
  }

  Future<void> play(bool? isAudio) async =>
      _play(await playbackRequest(fromBeginning: true, audio: isAudio));

  Future<void> playEntry(Video video, {bool? audio}) async =>
      _play(await playbackRequest(video: video, audio: audio));

  Future<void> resume({bool acceptMissing = false}) async =>
      _play(await playbackRequest(resume: true, acceptMissing: acceptMissing));

  Future<void> getAllVideos() async {
    await loader.retry();
    _syncLoader();
  }

  @override
  Future<void> close() async {
    await _loading.cancel();
    loader.release();
    scrollController.dispose();
    await super.close();
  }

  void setShowImage(bool showImage) {
    if (state.showImage == showImage) return;
    if (scrollController.hasClients) scrollController.jumpTo(0);
    if (!isClosed) emit(state.copyWith(showImage: showImage));
  }
}

@freezed
sealed class PlaylistState with _$PlaylistState {
  const factory PlaylistState({
    @Default(0) double loadingProgress,
    required Playlist playlist,
    @Default(true) bool loading,
    @Default('') String error,
    @Default(true) bool showImage,
  }) = _PlaylistState;
}
