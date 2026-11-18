import 'package:clipious/app/states/app.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Port of Muzza's MiniPlayer.kt and Thumbnail.kt horizontal drag thresholds.
/// The shared player retains
/// ownership of its queue and decoder. An unfinished drag belongs to the exact
/// queue occurrence and layout on which it began, including duplicate songs.
class MusicTrackSwipe extends StatelessWidget {
  final Widget child;
  final bool compact;

  const MusicTrackSwipe({super.key, required this.child, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<PlayerCubit>().state;
    final session = context.watch<AppCubit>().state;
    final viewport = MediaQuery.sizeOf(context).width;
    return LayoutBuilder(
      builder: (context, constraints) => _TrackSwipeGesture(
        key: ValueKey((
          session.profileId,
          session.sessionRevision,
          state.currentQueueId,
          constraints.maxWidth,
          viewport,
        )),
        profileId: session.profileId,
        sessionRevision: session.sessionRevision,
        queueId: state.currentQueueId,
        enabled: state.hasQueue,
        width: constraints.maxWidth,
        threshold: viewport * (compact ? 0.15 : 0.25),
        compact: compact,
        child: child,
      ),
    );
  }
}

class _TrackSwipeGesture extends StatefulWidget {
  final String? queueId;
  final String profileId;
  final int sessionRevision;
  final bool enabled;
  final double width;
  final double threshold;
  final bool compact;
  final Widget child;

  const _TrackSwipeGesture(
      {super.key,
      required this.queueId,
      required this.profileId,
      required this.sessionRevision,
      required this.enabled,
      required this.width,
      required this.threshold,
      required this.compact,
      required this.child});

  @override
  State<_TrackSwipeGesture> createState() => _TrackSwipeGestureState();
}

class _TrackSwipeGestureState extends State<_TrackSwipeGesture> {
  double _distance = 0;
  bool _dragging = false;

  void _reset() => setState(() {
        _distance = 0;
        _dragging = false;
      });

  void _finish() {
    final distance = _distance;
    final wasDragging = _dragging;
    _reset();
    if (!mounted || !wasDragging || !widget.enabled) return;
    final player = context.read<PlayerCubit>();
    final session = context.read<AppCubit>().state;
    if (player.isClosed ||
        session.profileId != widget.profileId ||
        session.sessionRevision != widget.sessionRevision ||
        session.globalLoading ||
        session.sessionRecoveryRequired ||
        player.state.currentQueueId != widget.queueId ||
        !player.state.hasQueue ||
        !TickerMode.of(context)) {
      return;
    }
    if (distance.abs() <= widget.threshold) return;
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    if (distance * direction > 0) {
      player.playPrevious();
    } else {
      player.playNext();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width.isFinite ? widget.width : 1.0;
    final distance = _distance.clamp(-width, width);
    final showHint =
        distance.abs() * MediaQuery.devicePixelRatioOf(context) > 50;
    final previous =
        (distance > 0) == (Directionality.of(context) == TextDirection.ltr);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Buttons and focus navigation remain the accessible alternatives.
      excludeFromSemantics: true,
      onHorizontalDragStart: !widget.enabled
          ? null
          : (_) => setState(() {
                _dragging = true;
                _distance = 0;
              }),
      onHorizontalDragUpdate: !widget.enabled
          ? null
          : (details) => setState(() => _distance += details.delta.dx),
      onHorizontalDragEnd: !widget.enabled ? null : (_) => _finish(),
      onHorizontalDragCancel: _reset,
      child: ClipRect(
        child: Stack(alignment: Alignment.center, children: [
          if (widget.compact && showHint)
            Positioned(
              left: distance > 0 ? 16 : null,
              right: distance < 0 ? 16 : null,
              child: ExcludeSemantics(
                  child: Icon(
                      previous
                          ? Icons.skip_previous_rounded
                          : Icons.skip_next_rounded,
                      color: const Color(0xfff0f0f0))),
            ),
          AnimatedSlide(
            offset: Offset(width <= 0 ? 0 : distance / width, 0),
            duration: _dragging
                ? Duration.zero
                : AppMotion.duration(
                    context, const Duration(milliseconds: 300)),
            curve: Curves.easeOutCubic,
            child: widget.child,
          ),
        ]),
      ),
    );
  }
}
