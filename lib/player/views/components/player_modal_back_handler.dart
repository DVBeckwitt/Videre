import 'package:back_button_interceptor/back_button_interceptor.dart';
import 'package:flutter/material.dart';

/// Dismiss player dialogs before the player's global Back handler can minimize
/// playback or leave fullscreen. Only the current route intercepts the event.
class PlayerModalBackHandler extends StatefulWidget {
  final Widget child;

  const PlayerModalBackHandler({super.key, required this.child});

  @override
  State<PlayerModalBackHandler> createState() => _PlayerModalBackHandlerState();
}

class _PlayerModalBackHandlerState extends State<PlayerModalBackHandler> {
  @override
  void initState() {
    super.initState();
    BackButtonInterceptor.add(_handleBack,
        zIndex: 3, ifNotYetIntercepted: true);
  }

  bool _handleBack(bool stopDefaultButtonEvent, RouteInfo info) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    Navigator.of(context).pop();
    return true;
  }

  @override
  void dispose() {
    BackButtonInterceptor.remove(_handleBack);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
