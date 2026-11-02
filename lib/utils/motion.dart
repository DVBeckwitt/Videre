import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import 'motion_binding.dart';

enum MotionPreference {
  system,
  reduced,
  off;

  String label(AppLocalizations locals) => switch (this) {
        system => locals.followSystem,
        reduced => locals.animationsReduced,
        off => locals.animationsOff,
      };
}

enum MotionLevel { full, reduced, off }

/// Visual timing only. Playback, gesture debouncing and notification timeouts
/// must keep their own timing even when interface motion is disabled.
abstract final class AppMotion {
  static MotionLevel of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MotionData>()?.level ??
      (MediaQuery.maybeDisableAnimationsOf(context) == true
          ? MotionLevel.off
          : MotionLevel.full);

  static bool allowsMovement(BuildContext context) =>
      of(context) == MotionLevel.full;

  static Duration duration(BuildContext context,
          [Duration normal = const Duration(milliseconds: 250)]) =>
      allowsMovement(context) ? normal : Duration.zero;

  static Duration fadeDuration(BuildContext context,
          [Duration normal = const Duration(milliseconds: 250)]) =>
      switch (of(context)) {
        MotionLevel.full => normal,
        MotionLevel.reduced => normal > const Duration(milliseconds: 100)
            ? const Duration(milliseconds: 100)
            : normal,
        MotionLevel.off => Duration.zero,
      };

  static AnimationStyle? dialogStyle(BuildContext context) =>
      of(context) == MotionLevel.full
          ? null
          : AnimationStyle(
              duration: fadeDuration(context),
              reverseDuration: fadeDuration(context));

  static Future<void> scrollTo(
      BuildContext context, ScrollController controller, double offset,
      {Duration duration = const Duration(milliseconds: 250)}) async {
    if (!controller.hasClients) return;
    if (allowsMovement(context) && duration > Duration.zero) {
      await controller.animateTo(offset,
          duration: duration, curve: Curves.easeInOutQuad);
    } else {
      // ScrollController.animateTo rejects a zero duration.
      controller.jumpTo(offset);
    }
  }
}

/// Lives above the Navigator, so routes, dialogs and overlays share the policy.
/// Android's Remove animations setting always takes precedence.
class MotionScope extends StatelessWidget {
  final MotionPreference preference;
  final Widget child;

  const MotionScope({super.key, required this.preference, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final level = media.disableAnimations
        ? MotionLevel.off
        : switch (preference) {
            MotionPreference.system => MotionLevel.full,
            MotionPreference.reduced => MotionLevel.reduced,
            MotionPreference.off => MotionLevel.off,
          };
    final restricted = level != MotionLevel.full;
    final binding = WidgetsBinding.instance;
    if (binding is InterfaceMotionBinding) {
      binding.reduceInterfaceMotion = restricted;
    }
    final theme = Theme.of(context);
    final scrollBehavior = ScrollConfiguration.of(context);
    return _MotionData(
      level: level,
      child: MediaQuery(
        data: media.copyWith(disableAnimations: restricted),
        child: Theme(
          data: theme.copyWith(
            pageTransitionsTheme: PageTransitionsTheme(builders: {
              ...theme.pageTransitionsTheme.builders,
              TargetPlatform.android: _MotionPageTransitionsBuilder(level),
            }),
            splashFactory:
                restricted ? NoSplash.splashFactory : theme.splashFactory,
          ),
          child: ScrollConfiguration(
            behavior: restricted
                ? scrollBehavior.copyWith(overscroll: false)
                : scrollBehavior,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _MotionData extends InheritedWidget {
  final MotionLevel level;
  const _MotionData({required this.level, required super.child});

  @override
  bool updateShouldNotify(_MotionData oldWidget) => level != oldWidget.level;
}

/// Keep progress and loading semantics visible without a repeating animation.
/// Determinate progress still rebuilds as the operation advances.
class MotionLoadingIndicator extends StatelessWidget {
  final Widget child;
  const MotionLoadingIndicator({super.key, required this.child});

  @override
  Widget build(BuildContext context) => TickerMode(
      enabled: AppMotion.of(context) != MotionLevel.off, child: child);
}

class _MotionPageTransitionsBuilder extends PageTransitionsBuilder {
  final MotionLevel level;
  const _MotionPageTransitionsBuilder(this.level);

  @override
  Duration get transitionDuration => switch (level) {
        MotionLevel.full => const Duration(milliseconds: 300),
        MotionLevel.reduced => const Duration(milliseconds: 100),
        MotionLevel.off => Duration.zero,
      };

  @override
  Widget buildTransitions<T>(
      PageRoute<T> route,
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child) {
    return switch (AppMotion.of(context)) {
      MotionLevel.off => child,
      MotionLevel.reduced => FadeTransition(opacity: animation, child: child),
      MotionLevel.full => const PageTransitionsTheme().buildTransitions(
          route, context, animation, secondaryAnimation, child),
    };
  }
}
