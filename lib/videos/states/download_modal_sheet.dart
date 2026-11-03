import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/videos/models/adaptive_format.dart';

part 'download_modal_sheet.freezed.dart';

class DownloadModalSheetCubit extends Cubit<DownloadModalSheetState> {
  final Video video;
  late final IDbClient _source;
  late final IDbClient _owner;
  late final Service _client;
  late final Future<Server> _account;
  bool _pending = false;

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

  Future<void> init() async {
    if (_pending || !_current) return;
    _pending = true;
    emit(state.copyWith(loading: true, failed: false));
    Server? account;
    try {
      account = await _account;
      if (!await _isCurrentAccount(account)) return;
      final vid =
          await _client.getVideo(video.videoId, serverOverride: account);
      if (!await _isCurrentAccount(account)) return;

      final formats = vid.adaptiveFormats ?? <AdaptiveFormat>[];
      // Match the existing downloader's supported streams. Audio-only remains
      // available when no compatible video stream is present.
      final hasAudio = formats.any((f) => f.type.contains('audio/webm'));
      final byQuality = <String, AdaptiveFormat>{};
      for (final format in formats) {
        final label = format.qualityLabel;
        if (format.encoding == 'vp9' &&
            format.type.contains('video/webm') &&
            label != null &&
            label.trim().isNotEmpty) {
          byQuality.putIfAbsent(label, () => format);
        }
      }
      int height(AdaptiveFormat format) =>
          int.tryParse(RegExp(r'^\d+').stringMatch(
                  format.resolution ?? format.qualityLabel ?? '') ??
              '') ??
          0;
      final qualities = byQuality.values.toList()
        ..sort((a, b) => height(a).compareTo(height(b)));
      emit(state.copyWith(
          availableQualities: qualities,
          loading: false,
          failed: !hasAudio,
          audioOnly: qualities.isEmpty || state.audioOnly,
          quality: qualities.lastOrNull?.qualityLabel ?? state.quality));
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
    if (!_current || (!value && state.availableQualities.isEmpty)) return;
    emit(state.copyWith(audioOnly: value));
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
      @Default([]) List<AdaptiveFormat> availableQualities,
      @Default('720p') String quality}) = _DownloadModalSheetState;
}
