import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/services/download_audio_tracks.dart';

part 'download_modal_sheet.freezed.dart';

class DownloadModalSheetCubit extends Cubit<DownloadModalSheetState> {
  final Video video;
  late final IDbClient _source;
  late final IDbClient _owner;
  late final Service _client;
  late final Future<Server> _account;
  bool _pending = false;
  Video? _metadata;

  DownloadModalSheetCubit(super.initialState, this.video) {
    _source = db;
    _owner = db.forProfile(db.profileId);
    _client = service;
    _account = _owner.getCurrentlySelectedServer();
    unawaited(init());
  }

  bool get _current =>
      !isClosed && identical(db, _source) && db.profileId == _owner.profileId;

  Future<bool> _isCurrentAccount(Server account) async {
    if (!_current) return false;
    try {
      final selected = await _source.getCurrentlySelectedServer();
      return _current &&
          selected.profileId == account.profileId &&
          selected.accountId == account.accountId;
    } catch (_) {
      return false;
    }
  }

  Future<bool> canStartDownload() async {
    try {
      return await _isCurrentAccount(await _account);
    } catch (_) {
      return false;
    }
  }

  Future<void> init() async {
    if (_pending || !_current) return;
    _pending = true;
    emit(state.copyWith(loading: true, failed: false));
    Server? account;
    try {
      account = await _account;
      if (!await _isCurrentAccount(account)) return;
      var vid = await _client.getVideo(video.videoId, serverOverride: account);
      if (!await _isCurrentAccount(account)) return;
      var audioTrackDiscoveryFailed = false;
      try {
        vid = await loadDownloadAudioTracks(vid, account,
            client: _client.httpClient);
      } catch (_) {
        audioTrackDiscoveryFailed = true;
      }
      if (!await _isCurrentAccount(account)) return;

      _metadata = vid;
      final formats = DownloadFormats(vid.adaptiveFormats);
      final qualities = formats.videoOptions();
      emit(state.copyWith(
          audioTrackDiscoveryFailed: audioTrackDiscoveryFailed,
          audioTracks: formats.audioTracks,
          captions: vid.captions,
          availableQualities: qualities,
          loading: false,
          failed: formats.audioContainer == null,
          audioOnly: qualities.isEmpty || state.audioOnly,
          quality: qualities.lastOrNull?.qualityLabel ?? state.quality));
      _refreshFormats();
    } catch (_) {
      if (_current && (account == null || await _isCurrentAccount(account))) {
        emit(state
            .copyWith(loading: false, failed: true, availableQualities: []));
      }
    } finally {
      _pending = false;
    }
  }

  void setAudioOnly(bool value) {
    if (!_current || (!value && !canSelectVideo)) return;
    emit(state.copyWith(
        audioOnly: value, captionLabel: value ? null : state.captionLabel));
    _refreshFormats();
  }

  bool get canSelectVideo => DownloadFormats(_metadata?.adaptiveFormats,
          audioTrackId: state.audioTrackId)
      .videoOptions()
      .isNotEmpty;

  void setContainer(DownloadContainer? container) {
    if (!_current) return;
    emit(state.copyWith(container: container));
    _refreshFormats();
  }

  void setAudioTrack(String? id) {
    if (!_current ||
        (id != null && !state.audioTracks.any((track) => track.id == id))) {
      return;
    }
    emit(state.copyWith(audioTrackId: id));
    _refreshFormats();
  }

  void setCaption(String? label) {
    if (_current &&
        !state.audioOnly &&
        (label == null || state.captions.any((c) => c.label == label))) {
      emit(state.copyWith(captionLabel: label));
    }
  }

  void _refreshFormats() {
    final formats = DownloadFormats(_metadata?.adaptiveFormats,
        audioTrackId: state.audioTrackId);
    final audioOnly = state.audioOnly || formats.videoOptions().isEmpty;
    final containers = DownloadContainer.values
        .where((container) =>
            formats.audioFor(container) != null &&
            (audioOnly ||
                formats.videoOptions(container: container).isNotEmpty))
        .toList();
    final container =
        containers.contains(state.container) ? state.container : null;
    final qualities = formats.videoOptions(container: container);
    final selected = formats.videoFor(state.quality, container: container);
    emit(state.copyWith(
        container: container,
        audioOnly: audioOnly,
        captionLabel: audioOnly ? null : state.captionLabel,
        availableContainers: containers,
        availableQualities: qualities,
        quality: selected?.qualityLabel ?? state.quality,
        failed: formats.audioContainer == null));
  }

  void setQuality(String? quality) {
    if (_current &&
        quality != null &&
        state.availableQualities.any((f) => f.qualityLabel == quality)) {
      emit(state.copyWith(quality: quality));
    }
  }
}

@freezed
sealed class DownloadModalSheetState with _$DownloadModalSheetState {
  const factory DownloadModalSheetState(
      {@Default(false) bool audioOnly,
      @Default(false) bool loading,
      @Default(false) bool failed,
      @Default(false) bool audioTrackDiscoveryFailed,
      @Default([]) List<AdaptiveFormat> availableQualities,
      @Default([]) List<DownloadContainer> availableContainers,
      @Default([]) List<AudioTrack> audioTracks,
      @Default([]) List<Caption> captions,
      DownloadContainer? container,
      String? audioTrackId,
      String? captionLabel,
      @Default('720p') String quality}) = _DownloadModalSheetState;
}
