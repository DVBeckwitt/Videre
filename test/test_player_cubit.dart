import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';

class TestPlayerCubit extends PlayerCubit {
  TestPlayerCubit(super.initialState, super.settings);

  @override
  Future<void> onReady() async {}

  @override
  void mapMediaEventToMediaHandler(MediaEvent event) {}
}
