import 'package:bloc/bloc.dart';
import 'package:flutter/cupertino.dart';

class VideoQueueCubit extends Cubit<ScrollController> {
  VideoQueueCubit(super.initialState);

  @override
  Future<void> close() {
    state.dispose();
    return super.close();
  }
}
