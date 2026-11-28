import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/services/download_recovery.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/adaptive_format.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/services/download_audio_tracks.dart';
import 'package:dio/dio.dart';

part 'download_modal_sheet.freezed.dart';

class DownloadModalSheetCubit extends Cubit<DownloadModalSheetState> {
  final Video video;
  late final IDbClient _source;
  late final IDbClient _owner;
  late final Service _client;
  late final Future<Server> _account;
  final _token = CancelToken();
  DownloadRecovery? _loadedRecovery;
  bool _pending = false;
  bool _restrictedHandoff = false;
  Video? _metadata;

  DownloadModalSheetCubit(super.initialState, this.video) {
    _source = db;
    _owner = db.forProfile(db.profileId);
    _client = service;
    _account = _owner.getCurrentlySelectedServer();
    unawaited(init());
  }

  bool get _current =>
      !isClosed &&
      !_token.isCancelled &&
      identical(db, _source) &&
      db.profileId == _owner.profileId;

  bool _isCurrentAccount(Server account) =>
      _current && _owner.getAccount(account.accountId)?.inUse == true;

  bool get canHandOffDownload => _current && !_restrictedHandoff;

  Future<bool> canStartDownload() async {
    try {
      if (!_isCurrentAccount(await _account)) return false;
      final recovery = _loadedRecovery;
      if (recovery == null) return false;
      recovery.checkCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> init() async {
    if (_pending || !_current) return;
    _pending = true;
    _loadedRecovery = null;
    emit(state.copyWith(loading: true, failed: false, retryAt: null));
    Server? account;
    try {
      final selected = account = await _account;
      if (!_isCurrentAccount(selected)) return;
      final recovery =
          await DownloadRecovery.start(_client, _owner, selected, _token);
      void checkSelected() {
        if (!_isCurrentAccount(selected)) {
          throw StateError('The selected download account changed.');
        }
        recovery.checkCurrent();
      }

      final (vid, audioTrackDiscoveryFailed) =
          await recovery.run((route) async {
        checkSelected();
        var vid = await _client.getDownloadVideo(video.videoId,
            route: route, checkCurrent: checkSelected);
        checkSelected();
        if (vid.videoId == video.videoId &&
            vid.hasRestrictedDownloadVisibility) {
          _restrictedHandoff = true;
        }
        vid = vid.copyWith(
            adaptiveFormats: vid.adaptiveFormats
                ?.where(
                    (format) => downloadMediaUrl(format, route.server) != null)
                .toList());
        var discoveryFailed = false;
        try {
          vid = await loadDownloadAudioTracks(vid, route.server,
              client: _client.httpClient, checkCurrent: checkSelected);
        } catch (error) {
          // Instance-wide cooldowns and gateway refusals apply to the download
          // too, even if the original metadata has a playable audio track.
          if (error is InvidiousServiceError &&
              (error.isGatewayAccessFailure ||
                  error.isRateLimited ||
                  error.retryAfterIsInvalid ||
                  (error.retryAfter ?? Duration.zero) > Duration.zero)) {
            rethrow;
          }
          if (DownloadFormats(vid.adaptiveFormats).audioContainer == null) {
            rethrow;
          }
          discoveryFailed = true;
        }
        checkSelected();
        if (DownloadFormats(vid.adaptiveFormats).audioContainer == null) {
          throw const DownloadFormatsUnavailable();
        }
        return (vid, discoveryFailed);
      }, onWaiting: (retryAt) {
        if (_isCurrentAccount(selected)) emit(state.copyWith(retryAt: retryAt));
      });
      checkSelected();
      _loadedRecovery = recovery;

      _metadata = vid;
      final formats = DownloadFormats(vid.adaptiveFormats);
      final qualities = formats.videoOptions();
      emit(state.copyWith(
          audioTrackDiscoveryFailed: audioTrackDiscoveryFailed,
          audioTracks: formats.audioTracks,
          captions: vid.captions,
          availableQualities: qualities,
          loading: false,
          failed: false,
          retryAt: null,
          audioOnly: qualities.isEmpty || state.audioOnly,
          quality: qualities.lastOrNull?.qualityLabel ?? state.quality));
      _refreshFormats();
    } catch (error) {
      if (_current && (account == null || _isCurrentAccount(account))) {
        emit(state.copyWith(
            loading: false,
            failed: true,
            retryAt: error is DownloadCooldown ? error.retryAt : null,
            availableQualities: []));
      }
    } finally {
      _pending = false;
    }
  }

  void cancel() => _token.cancel();

  @override
  Future<void> close() {
    cancel();
    return super.close();
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

  double? estimatedDownloadSize(AdaptiveFormat video) {
    final audio = DownloadFormats(_metadata?.adaptiveFormats,
            audioTrackId: state.audioTrackId)
        .audioFor(DownloadContainer.forVideo(video));
    final videoSize = double.tryParse(video.clen);
    final audioSize = double.tryParse(audio?.clen ?? '');
    if (videoSize == null ||
        audioSize == null ||
        !videoSize.isFinite ||
        !audioSize.isFinite ||
        videoSize <= 0 ||
        audioSize <= 0) {
      return null;
    }
    final total = videoSize + audioSize;
    return total.isFinite ? total : null;
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
      DateTime? retryAt,
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
