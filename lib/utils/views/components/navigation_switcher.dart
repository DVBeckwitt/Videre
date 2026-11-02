import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';

class NavigationSwitcher extends StatelessWidget {
  final Widget child;
  const NavigationSwitcher({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      switchInCurve: Curves.easeInOutQuad,
      switchOutCurve: Curves.easeInOutQuad,
      transitionBuilder: (Widget child, Animation<double> animation) {
        final fade = FadeTransition(opacity: animation, child: child);
        if (!AppMotion.allowsMovement(context)) return fade;
        return ScaleTransition(
          scale: Tween<double>(begin: 0.95, end: 1).animate(animation),
          child: fade,
        );
      },
      duration: AppMotion.fadeDuration(context),
      child: child,
    );
  }
}
