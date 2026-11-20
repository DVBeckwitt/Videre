import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:clipious/player/states/player.dart';

import '../models/db/history_video_cache.dart';
import '../models/video.dart';

part 'history.freezed.dart';

enum HistorySource {
  video(PlaybackHistoryOrigin.video),
  music(PlaybackHistoryOrigin.music),
  device(null),
  server(null);

  final PlaybackHistoryOrigin? origin;
  const HistorySource(this.origin);

  String label(AppLocalizations locals) => switch (this) {
        video => locals.videoPlaybackHistory,
        music => locals.musicPlaybackHistory,
        device => locals.combinedDeviceHistory,
        server => locals.combinedServerHistory,
      };

  Future<List<String>> page(int page, int maxResults) => switch (this) {
        device => service.getLocalHistoryPage(page, maxResults),
        server => service.getUserHistory(page, maxResults),
        _ => service.getPlaybackHistoryPage(origin!, page, maxResults),
      };

  HistoryVideoCache? cached(String id) => origin == null
      ? db.getHistoryVideoByVideoId(id)
      : db.getPlaybackHistoryVideo(origin!, id);

  bool opensMusic(Video entry, HistoryVideoCache? cached) {
    final section = origin ?? (this == device ? cached?.origin : null);
    return section == null
        ? entry.musicMetadata != null
        : section == PlaybackHistoryOrigin.music;
  }
}

class HistoryCubit extends Cubit<void> {
  final ItemListCubit<String> historyListCubit;
  final HistorySource source;

  HistoryCubit(super.initialState, this.historyListCubit,
      {required this.source});

  Future<void> removeFromHistory(String videoId) async {
    await switch (source) {
      HistorySource.device => db.deleteLocalHistory(videoId),
      HistorySource.server => service.deleteFromUserHistory(videoId),
      _ => db.deletePlaybackHistory(source.origin!, videoId),
    };
    if (source != HistorySource.server) playbackHistoryRevision.value++;
    await historyListCubit.refreshItems();
  }

  Future<void> clearHistory() async {
    await switch (source) {
      HistorySource.device => db.clearLocalHistory(),
      HistorySource.server => service.clearUserHistory(),
      _ => db.clearPlaybackHistory(source.origin!),
    };
    if (source != HistorySource.server) playbackHistoryRevision.value++;
    await historyListCubit.refreshItems();
  }
}

class HistoryItemCubit extends Cubit<HistoryItemState> {
  final HistorySource source;
  HistoryItemCubit(super.initialState, {this.source = HistorySource.device}) {
    onReady();
  }

  void onReady() {
    getVideo();
  }

  getVideo() async {
    emit(state.copyWith(loading: true));

    // Rendering server history must not create a local watch entry, especially
    // if its metadata finishes after the row has been removed.
    final origin = source.origin;
    final cachedVid = origin == null
        ? await HistoryVideoCache.fromVideoIdToVideo(state.videoId,
            cacheFetched: false)
        : db.getPlaybackHistoryVideo(origin, state.videoId);

    if (!isClosed) {
      emit(state.copyWith(cachedVid: cachedVid, loading: false));
    }
  }
}

@freezed
sealed class HistoryItemState with _$HistoryItemState {
  const factory HistoryItemState(
      {required String videoId,
      @Default(true) bool loading,
      HistoryVideoCache? cachedVid}) = _HistoryItemState;
}
