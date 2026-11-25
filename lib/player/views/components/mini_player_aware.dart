import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/flow_floating_mini.dart';
import 'package:clipious/podcasts/views/podcast_player_controls.dart';

bool usesCompactMusicNavigation(BuildContext context) =>
    MediaQuery.sizeOf(context).height < 480;

double phoneNavigationHeight(BuildContext context, {bool compact = false}) {
  if (compact) return kMinInteractiveDimension;
  return MediaQuery.textScalerOf(context).scale(12) <= 16 ? 60 : 76;
}

class MiniPlayerDockController extends ChangeNotifier {
  Object? _owner;

  bool get active => _owner != null;

  void setActive(Object owner, bool value) {
    final wasActive = active;
    if (value) {
      _owner = owner;
    } else if (identical(_owner, owner)) {
      _owner = null;
    }
    if (wasActive != active && hasListeners) notifyListeners();
  }
}

/// Shares the active Music dock between the routed phone page and the player
/// overlay. The keyboard inset here is the one above the routed Scaffolds.
class MiniPlayerDock extends InheritedWidget {
  final MiniPlayerDockController controller;
  final bool active;
  final bool keyboardVisible;
  final bool miniSuppressed;

  const MiniPlayerDock({
    super.key,
    required this.controller,
    required this.active,
    required this.keyboardVisible,
    required this.miniSuppressed,
    required super.child,
  });

  static MiniPlayerDock? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MiniPlayerDock>();

  @override
  bool updateShouldNotify(MiniPlayerDock oldWidget) =>
      active != oldWidget.active ||
      keyboardVisible != oldWidget.keyboardVisible ||
      miniSuppressed != oldWidget.miniSuppressed ||
      controller != oldWidget.controller;
}

class MiniPlayerAware extends StatelessWidget {
  final Widget child;
  final bool reserveSpace;

  const MiniPlayerAware(
      {super.key, required this.child, this.reserveSpace = true});

  @override
  Widget build(BuildContext context) =>
      SafeArea(child: MiniPlayerInset(enabled: reserveSpace, child: child));
}

class MiniPlayerInset extends StatefulWidget {
  final Widget child;
  final bool enabled;

  const MiniPlayerInset({super.key, required this.child, this.enabled = true});

  @override
  State<MiniPlayerInset> createState() => _MiniPlayerInsetState();
}

class _MiniPlayerInsetState extends State<MiniPlayerInset> {
  bool _moved = false;

  @override
  void didUpdateWidget(MiniPlayerInset oldWidget) {
    super.didUpdateWidget(oldWidget);
    _moved = widget.enabled != oldWidget.enabled;
  }

  @override
  Widget build(BuildContext context) {
    final moved = _moved;
    _moved = false;
    final mini = context.select((PlayerCubit cubit) =>
        !cubit.state.isHidden &&
        cubit.state.isMini &&
        !cubit.state.isClosing &&
        !usesFlowFloatingVideo(cubit.state));
    final podcasts = context.read<PlayerCubit>().podcasts;
    return ListenableBuilder(
      listenable: podcasts,
      child: widget.child,
      builder: (context, child) => AnimatedContainer(
        padding: EdgeInsets.only(
            bottom: !widget.enabled
                ? 0
                : podcasts.active
                    ? podcastBarHeight
                    : mini
                        ? targetHeight
                        : 0),
        duration: moved ? Duration.zero : AppMotion.duration(context),
        curve: Curves.easeInOutQuad,
        child: child,
      ),
    );
  }
}
