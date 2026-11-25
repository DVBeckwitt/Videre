import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

bool get supportsMusicScreenPrivacy =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Coordinates the single Android window shared by routed Music screens and
/// the expanded player. The scope stays mounted across profile changes.
class MusicScreenPrivacyScope extends StatefulWidget {
  const MusicScreenPrivacyScope({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  @override
  State<MusicScreenPrivacyScope> createState() =>
      _MusicScreenPrivacyScopeState();
}

class _MusicScreenPrivacyScopeState extends State<MusicScreenPrivacyScope> {
  final _window = _MusicPrivacyWindow();

  @override
  void dispose() {
    _window.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _MusicPrivacy(
        enabled: widget.enabled && supportsMusicScreenPrivacy,
        window: _window,
        child: widget.child,
      );
}

class _MusicPrivacy extends InheritedWidget {
  const _MusicPrivacy({
    required this.enabled,
    required this.window,
    required super.child,
  });

  final bool enabled;
  final _MusicPrivacyWindow window;

  @override
  bool updateShouldNotify(_MusicPrivacy oldWidget) =>
      enabled != oldWidget.enabled || window != oldWidget.window;
}

/// Marks visible Music content, including content behind transparent dialogs.
/// Retained tabs and pages covered by opaque routes have their tickers muted.
class MusicScreenPrivacySurface extends StatefulWidget {
  const MusicScreenPrivacySurface({
    super.key,
    this.active = true,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<MusicScreenPrivacySurface> createState() =>
      _MusicScreenPrivacySurfaceState();
}

class _MusicScreenPrivacySurfaceState extends State<MusicScreenPrivacySurface> {
  _MusicPrivacyWindow? _claim;

  @override
  void dispose() {
    _claim?.release(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_MusicPrivacy>();
    if (scope == null) return widget.child;

    final visible = TickerMode.of(context) && widget.active;
    final claim = scope.enabled && visible ? scope.window : null;
    if (_claim != claim) {
      _claim?.release(this);
      claim?.protect(this);
      _claim = claim;
    }

    return ValueListenableBuilder<bool>(
      valueListenable: scope.window.ready,
      builder: (context, ready, child) => Visibility(
        // A frame containing Music can be drawn as soon as Android confirms
        // the window is secure. Keep the subtree laid out during that wait.
        visible: claim == null || ready,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        maintainFocusability: true,
        child: child!,
      ),
      child: widget.child,
    );
  }
}

class _MusicPrivacyWindow {
  static const _channel = MethodChannel('videre/music_screen_privacy');

  final ready = ValueNotifier(false);
  final _surfaces = <Object>{};
  bool _requested = false;
  bool _disposed = false;
  int _revision = 0;

  void protect(Object surface) {
    _surfaces.add(surface);
    if (_requested) return;
    _requested = true;
    unawaited(_apply(true));
  }

  void release(Object surface) {
    if (!_surfaces.remove(surface) || _surfaces.isNotEmpty) return;
    // Allow incoming Music routes to take over in the same frame. Release only
    // after the frame that removed the last protected surface is submitted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _surfaces.isNotEmpty || !_requested) return;
      _requested = false;
      ready.value = false;
      unawaited(_apply(false));
    });
  }

  Future<void> _apply(bool protected) async {
    final revision = ++_revision;
    try {
      await _channel.invokeMethod<void>('setProtected', protected);
      if (!_disposed && revision == _revision) ready.value = protected;
    } on PlatformException catch (error) {
      debugPrint('Music screen privacy could not be applied: ${error.code}');
    } on MissingPluginException {
      debugPrint('Music screen privacy is unavailable.');
    }
  }

  void dispose() {
    _disposed = true;
    ready.dispose();
    if (_requested) unawaited(_apply(false));
  }
}
