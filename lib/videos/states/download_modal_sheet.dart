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

      final formats = DownloadFormats(vid.adaptiveFormats);
      final qualities = formats.videoOptions();
      emit(state.copyWith(
          availableQualities: qualities,
          loading: false,
          failed: formats.audioContainer == null,
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
