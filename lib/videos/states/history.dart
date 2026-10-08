import 'package:bloc/bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils/states/item_list.dart';
import 'package:clipious/player/states/player.dart';

import '../models/db/history_video_cache.dart';

part 'history.freezed.dart';

class HistoryCubit extends Cubit<void> {
  final ItemListCubit<String> historyListCubit;
  final bool local;

  HistoryCubit(super.initialState, this.historyListCubit, {this.local = false});

  removeFromHistory(String videoId) async {
    await (local
        ? db.deleteLocalHistory(videoId)
        : service.deleteFromUserHistory(videoId));
    if (local) playbackHistoryRevision.value++;
    historyListCubit.refreshItems();
  }

  clearHistory() async {
    await (local ? db.clearLocalHistory() : service.clearUserHistory());
    if (local) playbackHistoryRevision.value++;
    historyListCubit.refreshItems();
  }
}

class HistoryItemCubit extends Cubit<HistoryItemState> {
  HistoryItemCubit(super.initialState) {
    onReady();
  }

  void onReady() {
    getVideo();
  }

  getVideo() async {
    emit(state.copyWith(loading: true));

    var cachedVid = await HistoryVideoCache.fromVideoIdToVideo(state.videoId);

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
