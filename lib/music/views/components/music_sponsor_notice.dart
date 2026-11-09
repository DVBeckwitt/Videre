import 'dart:async';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/media_event.dart';
import 'package:clipious/player/states/player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Shared skip feedback for Music's artwork and TV audio presentations.
class MusicSponsorNotice extends StatefulWidget {
  const MusicSponsorNotice({super.key});

  @override
  State<MusicSponsorNotice> createState() => _MusicSponsorNoticeState();
}

class _MusicSponsorNoticeState extends State<MusicSponsorNotice> {
  Timer? _timer;
  String? _queueId;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _queueId = context.read<PlayerCubit>().state.currentQueueId;
  }

  void _onPlayerChanged(BuildContext context, PlayerState state) {
    if (_queueId != state.currentQueueId) {
      _queueId = state.currentQueueId;
      _timer?.cancel();
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (state.mediaEvent.type != MediaEventType.sponsorSkipped) return;
    _timer?.cancel();
    setState(() => _visible = true);
    _timer = Timer(const Duration(seconds: 3), () {
      setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<PlayerCubit, PlayerState>(
      listenWhen: (before, after) =>
          before.currentQueueId != after.currentQueueId ||
          before.mediaEvent != after.mediaEvent,
      listener: _onPlayerChanged,
      child: !_visible
          ? const SizedBox.shrink()
          : Semantics(
              container: true,
              liveRegion: true,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.fast_forward, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(AppLocalizations.of(context)!.sponsorSkipped,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
