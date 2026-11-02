import 'package:bloc/bloc.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'tv_video.freezed.dart';

double defaultBottomOffset = -400;

class TvVideoCubit extends Cubit<TvVideoState> {
  final ScrollController scrollController;

  TvVideoCubit(super.initialState, {ScrollController? scrollController})
      : scrollController = scrollController ?? ScrollController();

  @override
  close() async {
    scrollController.dispose();
    super.close();
  }

  scrollUp({Duration duration = const Duration(milliseconds: 125)}) {
    var state = this.state.copyWith();
    if (scrollController.hasClients) {
      if (duration == Duration.zero) {
        scrollController.jumpTo(0);
      } else {
        scrollController.animateTo(0,
            duration: duration, curve: Curves.easeInOutQuad);
      }
    }
    emit(state.copyWith(showImage: true));
  }

  scrollDown() {
    emit(state.copyWith(showImage: false));
  }
}

@freezed
sealed class TvVideoState with _$TvVideoState {
  const factory TvVideoState({@Default(true) bool showImage}) = _TvVideoState;
}
