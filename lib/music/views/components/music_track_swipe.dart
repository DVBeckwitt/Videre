import 'package:clipious/app/states/app.dart';
import 'package:clipious/player/models/playback_queue.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/ided_video.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

String? _occurrence(IdedVideo? entry) =>
    entry == null ? null : playbackQueueId(entry);

/// A swipe selects an adjacent occurrence in playback order. Taps and vertical
/// gestures remain available to the underlying controls and scrolling surface.
class MusicTrackSwipe extends StatelessWidget {
  final Widget child;
  final bool compact;
  final Widget Function(IdedVideo)? buildPreview;

  const MusicTrackSwipe(
      {super.key,
      required this.child,
      this.compact = false,
      this.buildPreview});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerCubit>();
    final (_, enabled) = context.select((SettingsCubit? settings) => (
          settings?.state.playerRepeatMode,
          compact || settings?.state.musicArtworkSwipe != false,
        ));
    final session = context.watch<AppCubit>().state;
    final current =
        _occurrence(player.openingMusicEntry) ?? player.state.currentQueueId;
    final previous = player.adjacentMusicEntry(previous: true);
    final next = player.adjacentMusicEntry(previous: false);
    return LayoutBuilder(
      builder: (context, constraints) => _TrackSwipeGesture(
        key: ValueKey((
          session.profileId,
          session.sessionRevision,
          current,
          _occurrence(previous),
          _occurrence(next),
          constraints.maxWidth,
        )),
        profileId: session.profileId,
        sessionRevision: session.sessionRevision,
        queueId: current,
        previous: previous,
        next: next,
        width: constraints.maxWidth,
        enabled: enabled,
        compact: compact,
        buildPreview: buildPreview,
        child: child,
      ),
    );
  }
}

class _TrackSwipeGesture extends StatefulWidget {
  final String? queueId;
  final String profileId;
  final int sessionRevision;
  final IdedVideo? previous;
  final IdedVideo? next;
  final double width;
  final bool enabled;
  final bool compact;
  final Widget Function(IdedVideo)? buildPreview;
  final Widget child;

  const _TrackSwipeGesture(
      {super.key,
      required this.queueId,
      required this.profileId,
      required this.sessionRevision,
      required this.previous,
      required this.next,
      required this.width,
      required this.enabled,
      required this.buildPreview,
      required this.compact,
      required this.child});

  @override
  State<_TrackSwipeGesture> createState() => _TrackSwipeGestureState();
}

class _TrackSwipeGestureState extends State<_TrackSwipeGesture> {
  double _distance = 0;
  bool _dragging = false;

  @override
  void didUpdateWidget(_TrackSwipeGesture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _distance = 0;
      _dragging = false;
    }
  }

  void _reset() => setState(() {
        _distance = 0;
        _dragging = false;
      });

  bool _previous(double distance) =>
      (distance > 0) == (Directionality.of(context) == TextDirection.ltr);

  IdedVideo? _neighbor(double distance) =>
      _previous(distance) ? widget.previous : widget.next;

  void _finish(DragEndDetails details) {
    final distance = _distance;
    final velocity = details.primaryVelocity ?? 0;
    final width = context.size!.width;
    final flick = distance.abs() >= kTouchSlop &&
        velocity.abs() >= 400 &&
        velocity.sign == distance.sign;
    if (!_dragging ||
        _neighbor(distance) == null ||
        (!flick && distance.abs() < width * (widget.compact ? 0.15 : 0.25))) {
      _reset();
      return;
    }
    final player = context.read<PlayerCubit>();
    final session = context.read<AppCubit>().state;
    if (player.isClosed ||
        player.state.isMini != widget.compact ||
        (!widget.compact &&
            context.read<SettingsCubit?>()?.state.musicArtworkSwipe == false) ||
        session.profileId != widget.profileId ||
        session.sessionRevision != widget.sessionRevision ||
        session.globalLoading ||
        session.sessionRecoveryRequired ||
        (_occurrence(player.openingMusicEntry) ??
                player.state.currentQueueId) !=
            widget.queueId ||
        !TickerMode.of(context)) {
      _reset();
      return;
    }
    final previous = _previous(distance);
    final expected = _occurrence(_neighbor(distance));
    if (_occurrence(player.adjacentMusicEntry(previous: previous)) !=
        expected) {
      _reset();
      return;
    }
    if (previous) {
      player.playPrevious();
    } else {
      player.playNext();
    }
    // An accepted skip gives the new occurrence its own centered gesture
    // widget. Only a rejected or cancelled gesture returns the old card.
    if ((_occurrence(player.openingMusicEntry) ??
            player.state.currentQueueId) ==
        widget.queueId) {
      _reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width.isFinite ? widget.width : 1.0;
    final distance = _neighbor(_distance) != null
        ? _distance.clamp(-width, width).toDouble()
        : widget.buildPreview == null
            ? 0.0
            : (_distance * 0.2).clamp(-width * 0.12, width * 0.12).toDouble();
    final showHint =
        distance.abs() * MediaQuery.devicePixelRatioOf(context) > 50;
    final enabled = widget.enabled &&
        (widget.next != null ||
            widget.previous != null ||
            widget.buildPreview != null);
    final gesture = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Buttons and focus navigation remain the accessible alternatives.
      excludeFromSemantics: true,
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: !enabled
          ? null
          : (_) => setState(() {
                _dragging = true;
                _distance = 0;
              }),
      onHorizontalDragUpdate: !enabled
          ? null
          : (details) => setState(() => _distance += details.delta.dx),
      onHorizontalDragEnd: !enabled ? null : _finish,
      onHorizontalDragCancel: enabled ? _reset : null,
      child: ClipRect(
        child: Stack(
            fit: widget.compact ? StackFit.loose : StackFit.passthrough,
            alignment: Alignment.center,
            children: [
              if (widget.compact && showHint)
                Positioned(
                  left: distance > 0 ? 16 : null,
                  right: distance < 0 ? 16 : null,
                  child: ExcludeSemantics(
                      child: Icon(
                          _previous(distance)
                              ? Icons.skip_previous_rounded
                              : Icons.skip_next_rounded,
                          color: const Color(0xfff0f0f0))),
                ),
              TweenAnimationBuilder<double>(
                tween: Tween(end: distance),
                duration: _dragging || !widget.enabled
                    ? Duration.zero
                    : AppMotion.duration(
                        context, const Duration(milliseconds: 300)),
                curve: Curves.easeOutCubic,
                child: widget.child,
                builder: (context, offset, child) {
                  final neighbor = _neighbor(offset);
                  return Stack(fit: StackFit.passthrough, children: [
                    if (offset != 0 &&
                        neighbor != null &&
                        widget.buildPreview != null)
                      Positioned.fill(
                        child: ExcludeSemantics(
                            child: IgnorePointer(
                          child: Transform.translate(
                            offset:
                                Offset(offset - offset.sign * (width + 12), 0),
                            child: widget.buildPreview!(neighbor),
                          ),
                        )),
                      ),
                    Transform.translate(
                        offset: Offset(offset, 0), child: child),
                  ]);
                },
              ),
            ]),
      ),
    );
    // The pinned SDK signals the end of an accepted drag even when Android
    // cancels the pointer. Retire it before that callback can commit a skip.
    return Listener(
        onPointerCancel: (_) {
          if (_dragging) _reset();
        },
        child: gesture);
  }
}
