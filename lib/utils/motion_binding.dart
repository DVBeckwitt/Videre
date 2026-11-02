import 'package:flutter/widgets.dart';

/// Framework controllers read SemanticsBinding, not a MediaQuery override.
/// Use Flutter's reduced-animation behavior for built-in controls as well as
/// the explicit visual durations used by Videre's own widgets.
mixin InterfaceMotionBinding on WidgetsBinding {
  bool reduceInterfaceMotion = false;

  @override
  bool get disableAnimations =>
      reduceInterfaceMotion || super.disableAnimations;
}

class VidereWidgetsBinding extends WidgetsFlutterBinding
    with InterfaceMotionBinding {}
