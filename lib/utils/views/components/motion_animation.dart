import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../motion.dart';

/// Owns a timeline whose effects already respect [AppMotion]. Flutter must not
/// shorten it again: delays can keep player feedback visible long enough to read.
class MotionAnimation extends StatefulWidget {
  final Widget Function(BuildContext, AnimationController) builder;

  const MotionAnimation({super.key, required this.builder});

  factory MotionAnimation.fadeIn({Key? key, required Widget child}) =>
      MotionAnimation(
          key: key,
          builder: (context, controller) => child
              .animate(controller: controller)
              .fadeIn(
                  duration: AppMotion.fadeDuration(context),
                  curve: Curves.linear));

  @override
  State<MotionAnimation> createState() => _MotionAnimationState();
}

class _MotionAnimationState extends State<MotionAnimation>
    with SingleTickerProviderStateMixin {
  late final controller = AnimationController(
      vsync: this, animationBehavior: AnimationBehavior.preserve);

  @override
  Widget build(BuildContext context) => widget.builder(context, controller);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}
