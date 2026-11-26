import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils/views/components/thumbnail.dart';
import '../../../videos/models/video.dart';
import '../../models/flow_mini_geometry.dart';
import '../../models/media_event.dart';
import '../../states/player.dart';

// Motion and controls translated from Flow 565d1f7a (GPL-3.0); see
// docs/flow-video-ui-sources.md for the exact upstream source ledger.
bool usesFlowFloatingVideo(PlayerState state) =>
    !isTv && !state.isAudio && state.hasVideo;

/// The settled corner, wide size and tucked edge from Flow's
/// PlayerDraggableState and MiniPlayerResnap. The decoder stays in Player.
class FlowFloatingMiniMotion {
  FlowMiniCorner _corner = FlowMiniCorner.bottomRight;
  bool _wide = false;
  Offset? _wideOrigin;
  FlowMiniTuckSide? tuckedSide;
  double? _tuckedY;
  Rect? _preview;
  Object? _viewport;

  bool get interacting => _preview != null;
  bool get isWide => _wide;
  double scale(FlowMiniGeometry geometry) => _wide ? geometry.maxScale : 1;

  /// A resize or inset change leaves the saved corner in control again.
  Rect bounds(FlowMiniGeometry geometry, Object viewport) {
    if (_viewport != viewport) {
      _viewport = viewport;
      _preview = null;
      _wideOrigin = null;
    }
    final currentScale = scale(geometry);
    final rest =
        geometry.rest(_corner, scale: currentScale, wideOrigin: _wideOrigin);
    if (tuckedSide case final side?) {
      return geometry.tucked(side,
          y: _tuckedY ?? rest.top, scale: currentScale);
    }
    return _preview ?? rest;
  }

  void reset() {
    _corner = FlowMiniCorner.bottomRight;
    _wide = false;
    _wideOrigin = null;
    _preview = null;
    untuck();
  }

  void cancel() => _preview = null;

  void toggleWide(FlowMiniGeometry geometry) {
    if (geometry.maxScale <= 1) return;
    _wide = !_wide;
    _wideOrigin = null;
    _preview = null;
  }

  void untuck() {
    tuckedSide = null;
    _tuckedY = null;
  }

  void drag(FlowMiniGeometry geometry, Offset origin) {
    _preview = geometry.drag(origin, scale: scale(geometry));
  }

  void pinch(FlowMiniGeometry geometry,
      {required Offset origin,
      required double startScale,
      required double size}) {
    _preview = geometry.pinch(
      corner: _corner,
      startOrigin: origin,
      startScale: startScale,
      scale: size,
    );
  }

  void settlePinch(FlowMiniGeometry geometry,
      {required Offset origin,
      required double startScale,
      required double size}) {
    final target = geometry.settledScale(size);
    _wide = geometry.isWide(target);
    _wideOrigin = _wide
        ? geometry
            .pinch(
                corner: _corner,
                startOrigin: origin,
                startScale: startScale,
                scale: target)
            .topLeft
        : null;
    _preview = null;
  }

  bool settleDrag(FlowMiniGeometry geometry, Offset origin, Offset velocity) {
    final drop = geometry.release(
        corner: _corner,
        rawOrigin: origin,
        velocity: velocity,
        scale: scale(geometry));
    _preview = null;
    _corner = drop.corner;
    tuckedSide = drop.tuckSide;
    _tuckedY = drop.tuckSide == null ? null : drop.rect.top;
    _wideOrigin = null;
    return drop.dismiss;
  }
}

/// Ports Flow's two-pointer pinch and mini tap decisions onto Flutter's
/// scale recognizer. Its focal point and span already use global coordinates.
class FlowFloatingMiniSurface extends StatefulWidget {
  final FlowMiniGeometry geometry;
  final Object viewport;
  final Rect bounds;
  final FlowFloatingMiniMotion motion;
  final VoidCallback onChanged;
  final VoidCallback onExpand;
  final VoidCallback onDismiss;
  final Widget child;

  const FlowFloatingMiniSurface({
    super.key,
    required this.geometry,
    required this.viewport,
    required this.bounds,
    required this.motion,
    required this.onChanged,
    required this.onExpand,
    required this.onDismiss,
    required this.child,
  });

  @override
  State<FlowFloatingMiniSurface> createState() =>
      _FlowFloatingMiniSurfaceState();
}

class _FlowFloatingMiniSurfaceState extends State<FlowFloatingMiniSurface> {
  final _pointers = <int>{};
  bool _ignoreRemainder = false;
  bool _multitouch = false;
  Offset? _origin;
  Offset? _focal;
  Offset? _rawOrigin;
  double? _startScale;
  double? _pinchScale;
  Timer? _pendingTap;

  @override
  void didUpdateWidget(covariant FlowFloatingMiniSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.viewport != widget.viewport && _pointers.isNotEmpty) {
      _ignoreRemainder = true;
      _resetMotion();
    }
  }

  void _resetMotion() {
    _origin = null;
    _focal = null;
    _rawOrigin = null;
    _startScale = null;
    _pinchScale = null;
  }

  void _pointerDown(PointerDownEvent event) {
    if (_pointers.isEmpty) {
      _ignoreRemainder = false;
      _multitouch = false;
      _resetMotion();
    }
    _pointers.add(event.pointer);
    _multitouch |= _pointers.length > 1;
    if (_multitouch) _pendingTap?.cancel();
  }

  void _pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _ignoreRemainder = true;
    _pendingTap?.cancel();
    _resetMotion();
    widget.motion.cancel();
    widget.onChanged();
  }

  void _start(ScaleStartDetails details) {
    if (_ignoreRemainder) return;
    _pendingTap?.cancel();
    _origin = widget.bounds.topLeft;
    _focal = details.focalPoint;
    _rawOrigin = null;
    _startScale = details.pointerCount > 1
        ? _pinchScale ?? widget.motion.scale(widget.geometry)
        : null;
  }

  void _update(ScaleUpdateDetails details) {
    final origin = _origin;
    final focal = _focal;
    if (_ignoreRemainder || origin == null || focal == null) return;
    final geometry = widget.geometry;
    if (details.pointerCount > 1) {
      final start = _startScale ?? widget.motion.scale(geometry);
      final size =
          geometry.pinchScale(startScale: start, distanceRatio: details.scale);
      _pinchScale = size;
      widget.motion
          .pinch(geometry, origin: origin, startScale: start, size: size);
    } else if (!_multitouch) {
      final rawOrigin = origin + details.focalPoint - focal;
      _rawOrigin = rawOrigin;
      widget.motion.drag(geometry, rawOrigin);
    } else {
      return;
    }
    widget.onChanged();
  }

  void _end(ScaleEndDetails details) {
    if (_ignoreRemainder || details.pointerCount > 1) return;
    final geometry = widget.geometry;
    var dismiss = false;
    if (_pinchScale case final size?) {
      widget.motion.settlePinch(geometry,
          origin: _origin ?? widget.bounds.topLeft,
          startScale: _startScale ?? widget.motion.scale(geometry),
          size: size);
      // Lifting either pinch finger commits the size. The remaining finger
      // must not drag or open the player while it is still on the screen.
      _ignoreRemainder = true;
    } else if (!_multitouch &&
        details.pointerCount == 0 &&
        _rawOrigin != null) {
      dismiss = widget.motion
          .settleDrag(geometry, _rawOrigin!, details.velocity.pixelsPerSecond);
    } else {
      widget.motion.cancel();
    }
    _resetMotion();
    widget.onChanged();
    if (dismiss) widget.onDismiss();
  }

  void _tap() {
    if (_multitouch || _ignoreRemainder) return;
    // Flow's timeout applies only to the video surface. A parent double-tap
    // recognizer would also delay the child controls in Flutter's gesture arena.
    if (_pendingTap case final tap? when tap.isActive) {
      tap.cancel();
      widget.motion.toggleWide(widget.geometry);
      widget.onChanged();
    } else {
      _pendingTap = Timer(kDoubleTapTimeout, widget.onExpand);
    }
  }

  @override
  void dispose() {
    _pendingTap?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _pointerDown,
      onPointerUp: (event) => _pointers.remove(event.pointer),
      onPointerCancel: _pointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onScaleStart: _start,
        onScaleUpdate: _update,
        onScaleEnd: _end,
        onTap: _tap,
        child: widget.child,
      ),
    );
  }
}

/// The controls in Flow's MiniPlayerSlot and MiniPlayerControls, backed by
/// the current PlayerCubit and painted over its existing video surface.
class FlowFloatingMiniControls extends StatelessWidget {
  static const _seekStep = Duration(seconds: 10);

  final bool largeWindow;
  final bool wide;
  final double scale;

  const FlowFloatingMiniControls({
    super.key,
    required this.largeWindow,
    required this.wide,
    required this.scale,
  });

  bool _canSeek(PlayerCubit player) {
    final state = player.state;
    final video = state.currentlyPlaying;
    final length = video?.lengthSeconds ??
        state.offlineCurrentlyPlaying?.lengthSeconds ??
        0;
    return player.canSeekCurrentMedia &&
        video?.liveNow != true &&
        video?.isUpcoming != true &&
        length > 0;
  }

  void _seekBy(PlayerCubit player, Duration offset) {
    if (_canSeek(player)) player.seek(player.state.position + offset);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    final state = context.select((PlayerCubit p) => (
          playing: p.state.isPlaying,
          buffering: p.state.mediaEvent.state == MediaState.buffering ||
              p.state.mediaEvent.state == MediaState.loading,
          ended: p.state.mediaEvent.state == MediaState.completed,
          previous: p.state.playedVideos.isNotEmpty,
          next: p.state.playQueue.isNotEmpty,
          canSeek: _canSeek(p),
          duration: p.duration,
          position: p.state.position,
        ));
    final locals = AppLocalizations.of(context)!;
    final progress = state.duration > Duration.zero
        ? (state.position.inMilliseconds / state.duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble()
        : 0.0;

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      final inset = size.width >= 110 ? 4.0 : 0.0;
      final touch =
          math.min(largeWindow ? 50.0 : 42.0, (size.width - 2 * inset) / 2);
      final smallTouch = math.min(
          (largeWindow ? 44.0 : 36.0) * scale.clamp(1, 1.6),
          size.height - touch - 8);
      final queueButtons = (state.previous ? 1 : 0) + (state.next ? 1 : 0);
      final seekTouch =
          math.min(smallTouch, (size.width - 2 * inset) / (queueButtons + 2));
      final showTimeSeek = wide && state.canSeek && seekTouch >= 34;
      final transportTouch = showTimeSeek ? seekTouch : smallTouch;
      return Stack(children: [
        Positioned(
          left: inset,
          top: 4,
          child: _roundControl(
            context,
            key: const ValueKey('watch-mini-play'),
            size: touch,
            label: state.playing ? locals.musicPause : locals.musicPlay,
            icon: state.playing
                ? Icons.pause_rounded
                : state.ended
                    ? Icons.replay_rounded
                    : Icons.play_arrow_rounded,
            buffering: state.buffering,
            onPressed: () {
              if (state.ended) {
                player.seek(Duration.zero);
                player.play();
              } else {
                player.togglePlaying();
              }
            },
          ),
        ),
        Positioned(
          right: inset,
          top: 4,
          child: _roundControl(
            context,
            key: const ValueKey('flow-mini-close'),
            size: touch,
            label: MaterialLocalizations.of(context).closeButtonLabel,
            icon: Icons.close_rounded,
            onPressed: player.hide,
          ),
        ),
        if (transportTouch >= 34 && (showTimeSeek || queueButtons > 0))
          Positioned(
            left: 0,
            right: 0,
            bottom: 4,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (state.previous)
                    _roundControl(
                      context,
                      size: transportTouch,
                      label: locals.musicPrevious,
                      icon: Icons.skip_previous_rounded,
                      onPressed: player.playPrevious,
                    ),
                  if (showTimeSeek) ...[
                    _roundControl(
                      context,
                      size: transportTouch,
                      label: locals.videoSeekBack10,
                      icon: Icons.replay_10_rounded,
                      onPressed: () => _seekBy(player, -_seekStep),
                    ),
                    _roundControl(
                      context,
                      size: transportTouch,
                      label: locals.videoSeekForward10,
                      icon: Icons.forward_10_rounded,
                      onPressed: () => _seekBy(player, _seekStep),
                    ),
                  ],
                  if (state.next)
                    _roundControl(
                      context,
                      size: transportTouch,
                      label: locals.musicNext,
                      icon: Icons.skip_next_rounded,
                      onPressed: player.playNext,
                    ),
                ]),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ]);
    });
  }

  Widget _roundControl(BuildContext context,
      {Key? key,
      required double size,
      required String label,
      required IconData icon,
      required VoidCallback onPressed,
      bool buffering = false}) {
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        key: key,
        tooltip: label,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: Colors.black54,
          foregroundColor: Colors.white,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: buffering
            ? SizedBox.square(
                dimension: math.min(20, size / 2),
                child: const CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : Icon(icon, size: math.min(24, size * .60)),
      ),
    );
  }
}

/// Switches the floating surface to the pending autoplay transition.
class FlowFloatingMiniOverlay extends StatelessWidget {
  final bool largeWindow;
  final double scale;

  const FlowFloatingMiniOverlay(
      {super.key, required this.largeWindow, required this.scale});

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerCubit>();
    return ValueListenableBuilder<VideoAutoplayCountdown?>(
      valueListenable: player.videoAutoplayCountdown,
      child: FlowFloatingMiniControls(largeWindow: largeWindow, scale: scale),
      builder: (context, countdown, controls) {
        if (countdown == null) return controls!;
        return _FlowFloatingMiniAutoplay(
          key: ValueKey(countdown.token),
          countdown: countdown,
          largeWindow: largeWindow,
          scale: scale,
          onPlayNow: () => player.playVideoAutoplayNow(countdown.token),
          onCancel: () => player.cancelVideoAutoplay(countdown.token),
        );
      },
    );
  }
}

class _FlowFloatingMiniAutoplay extends StatefulWidget {
  final VideoAutoplayCountdown countdown;
  final bool largeWindow;
  final double scale;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  const _FlowFloatingMiniAutoplay({
    required super.key,
    required this.countdown,
    required this.largeWindow,
    required this.scale,
    required this.onPlayNow,
    required this.onCancel,
  });

  @override
  State<_FlowFloatingMiniAutoplay> createState() =>
      _FlowFloatingMiniAutoplayState();
}

class _FlowFloatingMiniAutoplayState extends State<_FlowFloatingMiniAutoplay> {
  late final Future<File?> _savedArtwork = _readSavedArtwork();

  Future<File?> _readSavedArtwork() async {
    final video = widget.countdown.next;
    if (video is! DownloadedVideo || video.profileId != db.profileId)
      return null;
    final file = File(await video.thumbnailPath);
    return await file.exists() ? file : null;
  }

  Widget _artwork(BuildContext context) {
    final video = widget.countdown.next;
    if (video is DownloadedVideo && video.profileId == db.profileId) {
      return FutureBuilder<File?>(
        future: _savedArtwork,
        builder: (context, snapshot) {
          final file = snapshot.data;
          return file == null
              ? const SizedBox.shrink()
              : Image.file(file,
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stack) =>
                      const SizedBox.shrink());
        },
      );
    }
    if (video is Video && video.thumbnails.isNotEmpty) {
      return Thumbnail(
        thumbnails: video.thumbnails,
        images:
            video.deArrowThumbnailUrl == null ? video.videoThumbnails : null,
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface),
        fallback: const SizedBox.shrink(),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final countdown = widget.countdown;
    final locals = AppLocalizations.of(context)!;
    final title = switch (countdown.next) {
      Video(:final title) => title?.trim(),
      DownloadedVideo(:final title) => title.trim(),
      _ => null,
    };
    final labelStyle =
        Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white);
    final buttonStyle = IconButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: Colors.black54,
      minimumSize: Size.zero,
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    final progress = 1 -
        countdown.secondsRemaining / PlayerCubit.videoAutoplayCountdownSeconds;

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      final inset = math.min(4.0, size.shortestSide / 10);
      final playSize = math.min(
          (widget.largeWindow ? 52.0 : 44.0) * widget.scale.clamp(1, 1.6),
          size.shortestSide / 2);
      final cancelSpace =
          (math.max(size.width, size.height) - playSize) / 2 - inset;
      final cancelSize = math.min(widget.largeWindow ? 48.0 : 44.0,
          math.min(size.shortestSide / 2, cancelSpace));
      final labelHeight = math.min(24.0, (size.height - playSize) / 2 - inset);

      return Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: Colors.black),
        IgnorePointer(child: _artwork(context)),
        const IgnorePointer(child: ColoredBox(color: Colors.black54)),
        PositionedDirectional(
          start: 2 * inset,
          end: cancelSize + inset,
          top: inset,
          height: labelHeight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(locals.videoAutoplayNextIn(countdown.secondsRemaining),
                style: labelStyle),
          ),
        ),
        PositionedDirectional(
          end: inset,
          top: inset,
          width: cancelSize,
          height: cancelSize,
          child: IconButton(
            key: const ValueKey('flow-mini-autoplay-cancel'),
            tooltip: locals.cancel,
            onPressed: widget.onCancel,
            icon: const Icon(Icons.close_rounded),
            iconSize: math.min(24.0, cancelSize * .6),
            style: buttonStyle,
          ),
        ),
        Center(
          child: SizedBox.square(
            dimension: playSize,
            child: Stack(fit: StackFit.expand, children: [
              IconButton(
                key: const ValueKey('flow-mini-autoplay-play-now'),
                tooltip: locals.videoAutoplayPlayNow,
                onPressed: widget.onPlayNow,
                icon: const Icon(Icons.skip_next_rounded),
                iconSize: math.min(30.0, playSize * .6),
                style: buttonStyle,
              ),
              ExcludeSemantics(
                child: IgnorePointer(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    backgroundColor: Colors.white38,
                    value: progress,
                    strokeWidth: math.min(3.0, playSize / 8),
                  ),
                ),
              ),
            ]),
          ),
        ),
        if (title != null && title.isNotEmpty && labelHeight >= 18)
          PositionedDirectional(
            start: 2 * inset,
            end: 2 * inset,
            bottom: inset,
            height: labelHeight,
            child: Align(
              alignment: AlignmentDirectional.bottomStart,
              child: Text(title,
                  style: labelStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ),
      ]);
    });
  }
}

/// Flow's 28 by 64 dp MiniPlayerTuckHandle. The larger invisible hit margin
/// helps keyboard and touch accessibility without growing the tab itself.
class FlowMiniTuckHandle extends StatelessWidget {
  final FlowMiniTuckSide side;
  final VoidCallback onUntuck;

  const FlowMiniTuckHandle(
      {super.key, required this.side, required this.onUntuck});

  @override
  Widget build(BuildContext context) {
    final left = side == FlowMiniTuckSide.left;
    final colors = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context)!.videoPlayer;
    return Tooltip(
      message: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => onUntuck(),
        child: Align(
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          child: Material(
            color: colors.surfaceContainerHighest,
            elevation: 3,
            shape: RoundedRectangleBorder(
              borderRadius: left
                  ? const BorderRadius.horizontal(right: Radius.circular(16))
                  : const BorderRadius.horizontal(left: Radius.circular(16)),
            ),
            child: Semantics(
              label: label,
              button: true,
              child: InkWell(
                onTap: onUntuck,
                child: SizedBox(
                  width: 28,
                  height: 64,
                  child: Icon(left
                      ? Icons.chevron_right_rounded
                      : Icons.chevron_left_rounded),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
