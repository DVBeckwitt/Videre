import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps the Android display awake while the current foreground route shows
/// lyrics. Mount this around the lyrics themselves so status views release it.
class MusicLyricsKeepAwake extends StatefulWidget {
  final Widget child;

  const MusicLyricsKeepAwake({super.key, required this.child});

  @override
  State<MusicLyricsKeepAwake> createState() => _MusicLyricsKeepAwakeState();
}

class _MusicLyricsKeepAwakeState extends State<MusicLyricsKeepAwake>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('videre/music_lyrics_screen');
  static int _visibleReaders = 0;

  bool _routeIsCurrent = false;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeIsCurrent = ModalRoute.isCurrentOf(context) == true;
    _updateWakeRequest(WidgetsBinding.instance.lifecycleState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _updateWakeRequest(state);
  }

  void _updateWakeRequest(AppLifecycleState? state) {
    _setHolding(_routeIsCurrent && state == AppLifecycleState.resumed);
  }

  void _setHolding(bool holding) {
    if (_holding == holding) return;
    _holding = holding;
    // Incoming and outgoing reader widgets can overlap during navigation.
    final wasVisible = _visibleReaders > 0;
    _visibleReaders += holding ? 1 : -1;
    final isVisible = _visibleReaders > 0;
    if (wasVisible != isVisible) unawaited(_setReaderVisible(isVisible));
  }

  Future<void> _setReaderVisible(bool visible) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('setReaderVisible', visible);
    } on MissingPluginException {
      // The reader remains usable without a native host.
    } on PlatformException {
      // The Activity may be detaching during the lifecycle transition.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setHolding(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
