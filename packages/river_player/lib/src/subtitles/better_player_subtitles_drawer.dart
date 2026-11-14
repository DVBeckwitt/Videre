import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/subtitles/better_player_subtitle.dart';

class BetterPlayerSubtitlesDrawer extends StatefulWidget {
  final List<BetterPlayerSubtitle> subtitles;
  final BetterPlayerController betterPlayerController;
  final BetterPlayerSubtitlesConfiguration? betterPlayerSubtitlesConfiguration;
  final Stream<bool> playerVisibilityStream;

  const BetterPlayerSubtitlesDrawer({
    Key? key,
    required this.subtitles,
    required this.betterPlayerController,
    this.betterPlayerSubtitlesConfiguration,
    required this.playerVisibilityStream,
  }) : super(key: key);

  @override
  _BetterPlayerSubtitlesDrawerState createState() =>
      _BetterPlayerSubtitlesDrawerState();
}

class _BetterPlayerSubtitlesDrawerState
    extends State<BetterPlayerSubtitlesDrawer> {
  final RegExp htmlRegExp =
      // ignore: unnecessary_raw_strings
      RegExp(r"<[^>]*>", multiLine: true);
  late TextStyle _innerTextStyle;
  late TextStyle _outerTextStyle;

  BetterPlayerSubtitlesConfiguration get _configuration =>
      widget.betterPlayerSubtitlesConfiguration ?? setupDefaultConfiguration();
  bool _playerVisible = false;

  ///Stream used to detect if play controls are visible or not
  late StreamSubscription _visibilityStreamSubscription;

  @override
  void initState() {
    _visibilityStreamSubscription =
        widget.playerVisibilityStream.listen((state) {
      setState(() {
        _playerVisible = state;
      });
    });

    widget.betterPlayerController.videoPlayerController!
        .addListener(_updateState);
    widget.betterPlayerController.addEventsListener(_onPlayerEvent);
    widget.betterPlayerController.subtitleFontSize
        .addListener(_onFontSizeChanged);

    _updateTextStyles();
    super.initState();
  }

  void _onFontSizeChanged() {
    if (mounted) setState(_updateTextStyles);
  }

  void _updateTextStyles() {
    final fontSize = widget.betterPlayerController.subtitleFontSize.value ??
        _configuration.fontSize;
    _outerTextStyle = TextStyle(
        fontSize: fontSize,
        fontFamily: _configuration.fontFamily,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _configuration.outlineSize
          ..color = _configuration.outlineColor);

    _innerTextStyle = TextStyle(
        fontFamily: _configuration.fontFamily,
        color: _configuration.fontColor,
        fontSize: fontSize);
  }

  @override
  void didUpdateWidget(BetterPlayerSubtitlesDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.betterPlayerController != widget.betterPlayerController) {
      oldWidget.betterPlayerController.videoPlayerController
          ?.removeListener(_updateState);
      oldWidget.betterPlayerController.removeEventsListener(_onPlayerEvent);
      oldWidget.betterPlayerController.subtitleFontSize
          .removeListener(_onFontSizeChanged);
      widget.betterPlayerController.videoPlayerController
          ?.addListener(_updateState);
      widget.betterPlayerController.addEventsListener(_onPlayerEvent);
      widget.betterPlayerController.subtitleFontSize
          .addListener(_onFontSizeChanged);
    }
    if (oldWidget.betterPlayerController != widget.betterPlayerController ||
        oldWidget.betterPlayerSubtitlesConfiguration !=
            widget.betterPlayerSubtitlesConfiguration) {
      _updateTextStyles();
    }
  }

  @override
  void dispose() {
    widget.betterPlayerController.videoPlayerController!
        .removeListener(_updateState);
    widget.betterPlayerController.removeEventsListener(_onPlayerEvent);
    widget.betterPlayerController.subtitleFontSize
        .removeListener(_onFontSizeChanged);
    _visibilityStreamSubscription.cancel();
    super.dispose();
  }

  ///Called when player state has changed, i.e. new player position, etc.
  void _updateState() {
    if (mounted) setState(() {});
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (event.betterPlayerEventType == BetterPlayerEventType.changedSubtitles) {
      // A remembered track can finish loading while playback is paused, with
      // no native position event to redraw its first cue.
      _updateState();
    }
  }

  @override
  Widget build(BuildContext context) {
    final BetterPlayerSubtitle? subtitle = _getSubtitleAtCurrentPosition();
    widget.betterPlayerController.renderedSubtitle = subtitle;
    final List<String> subtitles = subtitle?.texts ?? [];
    final List<Widget> textWidgets =
        subtitles.map((text) => _buildSubtitleTextWidget(text)).toList();

    return Container(
      height: double.infinity,
      width: double.infinity,
      child: Padding(
        padding: EdgeInsets.only(
            bottom: _playerVisible
                ? _configuration.bottomPadding + 30
                : _configuration.bottomPadding,
            left: _configuration.leftPadding,
            right: _configuration.rightPadding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: textWidgets,
        ),
      ),
    );
  }

  BetterPlayerSubtitle? _getSubtitleAtCurrentPosition() {
    final value = widget.betterPlayerController.videoPlayerController?.value;
    if (value == null) {
      return null;
    }

    final Duration position = value.position;
    for (final BetterPlayerSubtitle subtitle
        in widget.betterPlayerController.subtitlesLines) {
      // Cue intervals exclude their end, so adjacent transcript lines switch
      // exactly at their shared boundary (including when seeking while paused).
      if (subtitle.start! <= position && subtitle.end! > position) {
        return subtitle;
      }
    }
    return null;
  }

  Widget _buildSubtitleTextWidget(String subtitleText) {
    return Row(children: [
      Expanded(
        child: Align(
          alignment: _configuration.alignment,
          child: _getTextWithStroke(subtitleText),
        ),
      ),
    ]);
  }

  Widget _getTextWithStroke(String subtitleText) {
    return Container(
      color: _configuration.backgroundColor,
      child: Stack(
        children: [
          if (_configuration.outlineEnabled)
            _buildHtmlWidget(subtitleText, _outerTextStyle)
          else
            const SizedBox(),
          _buildHtmlWidget(subtitleText, _innerTextStyle)
        ],
      ),
    );
  }

  Widget _buildHtmlWidget(String text, TextStyle textStyle) {
    return HtmlWidget(
      text,
      textStyle: textStyle,
    );
  }

  BetterPlayerSubtitlesConfiguration setupDefaultConfiguration() {
    return const BetterPlayerSubtitlesConfiguration();
  }
}
