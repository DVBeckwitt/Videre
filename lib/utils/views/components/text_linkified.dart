import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:clipious/player/states/player.dart';
import '../../models/invidious_linkifier.dart';
import '../../models/timestamp_linkifier.dart';
import 'external_link.dart';

class TextLinkified extends StatefulWidget {
  final String text;
  final Video? video;
  final PlayerCubit? player;

  const TextLinkified({super.key, required this.text, this.video, this.player});

  @override
  State<TextLinkified> createState() => _TextLinkifiedState();

  void openLink(BuildContext context, LinkableElement link) {
    if (link is UrlElement) {
      final uri = Uri.tryParse(link.url);
      if (uri == null) return;
      final app = context.read<AppCubit?>();
      if (app?.canOpenAppLink(uri) == true) {
        unawaited(app!.openAppLink(link.url, false));
      } else {
        unawaited(openExternalLink(context, uri));
      }
    } else if (link is TimestampElement) {
      final player = this.player;
      if (player == null) return;
      var split = link.url.split(':');
      if (split.length >= 2 && split.length <= 3) {
        bool hours = split.length == 3;
        Duration position = Duration(
            hours: hours ? int.parse(split[0]) : 0,
            minutes: int.parse(split[hours ? 1 : 0]),
            seconds: int.parse(split[hours ? 2 : 1]));
        var videoPlaying = (player.state.isPlaying) &&
            player.state.currentlyPlaying?.videoId == video?.videoId;
        if (videoPlaying) {
          player.seek(position);
        } else if (video != null) {
          player.playVideo([video!], startAt: position);
        }
      }
    }
  }
}

class _TextLinkifiedState extends State<TextLinkified> {
  SelectableLinkify? _text;
  String? _serverUrl;

  @override
  void didUpdateWidget(TextLinkified oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        (widget.player == null) != (oldWidget.player == null)) {
      _text = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _text = null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final linkifier = InvidiousLinkifier.of(context);
    final serverUrl = linkifier.server?.url;
    if (serverUrl != _serverUrl) {
      _serverUrl = serverUrl;
      _text = null;
    }
    // Linkify creates new gesture recognizers on every build. Rebuilding the
    // same paragraph would replace SelectableText's controller and erase an
    // active selection when the surrounding player updates.
    return _text ??= SelectableLinkify(
      text: widget.text,
      contextMenuBuilder: (context, editableTextState) =>
          AdaptiveTextSelectionToolbar.editableText(
              editableTextState: editableTextState),
      linkStyle: TextStyle(
          color: colorScheme.primary, decoration: TextDecoration.none),
      onOpen: (link) => widget.openLink(context, link),
      options: const LinkifyOptions(humanize: true, removeWww: true),
      linkifiers: [
        linkifier,
        if (widget.player != null) const TimestampLinkifier(),
      ],
    );
  }
}
