import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/cupertino.dart';

class TvHomeCubit extends Cubit<bool> {
  final ScrollController scrollController = ScrollController();
  Timer? _collapseTimer;
  TvHomeCubit(super.initialState);

  void menuItemFocusChanged(bool focus) {
    _collapseTimer?.cancel();
    if (isClosed) return;
    if (focus) {
      emit(true);
    } else {
      _collapseTimer = Timer(const Duration(milliseconds: 50), () {
        emit(false);
      });
    }
  }

  @override
  Future<void> close() {
    _collapseTimer?.cancel();
    scrollController.dispose();
    return super.close();
  }
}
