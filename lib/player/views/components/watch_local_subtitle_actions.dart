import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/services/watch_local_subtitles.dart';
import 'package:clipious/player/states/video_player.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:flutter/material.dart';

bool Function() captureWatchLocalSubtitleScope(VideoPlayerCubit video) {
  final player = video.player;
  final profile = db.profileId;
  final session = video.settings.appCubit.state.sessionRevision;
  final queueId = player.state.currentQueueId;
  final generation = player.backendPlaybackGeneration;
  final positionGeneration = player.playbackPositionGeneration;
  final videoId =
      video.state.offlineVideo?.videoId ?? video.state.video?.videoId;
  return () =>
      !video.isClosed &&
      !player.isClosed &&
      db.profileId == profile &&
      video.settings.appCubit.state.sessionRevision == session &&
      player.state.currentQueueId == queueId &&
      player.backendPlaybackGeneration == generation &&
      player.playbackPositionGeneration == positionGeneration &&
      (video.state.offlineVideo?.videoId ?? video.state.video?.videoId) ==
          videoId &&
      video.canManageLocalSubtitles;
}

class WatchLocalSubtitleActions extends StatefulWidget {
  const WatchLocalSubtitleActions({
    super.key,
    required this.video,
    required this.isCurrent,
    required this.onChanged,
    this.television = false,
  });

  final VideoPlayerCubit video;
  final bool Function() isCurrent;
  final VoidCallback onChanged;
  final bool television;

  @override
  State<WatchLocalSubtitleActions> createState() =>
      _WatchLocalSubtitleActionsState();
}

class _WatchLocalSubtitleActionsState extends State<WatchLocalSubtitleActions> {
  bool _busy = false;
  WatchLocalSubtitleResult? _result;

  Future<void> _run(Future<WatchLocalSubtitleResult> Function() action) async {
    final isCurrent = widget.isCurrent;
    if (_busy || !isCurrent()) return;
    setState(() {
      _busy = true;
      _result = null;
    });
    final result = await action();
    if (!mounted) return;
    final current = isCurrent();
    setState(() {
      _busy = false;
      _result = current ? result : null;
    });
    if (current && result == WatchLocalSubtitleResult.done) widget.onChanged();
  }

  Widget _action({
    required Key key,
    required IconData icon,
    required String label,
    String? fileName,
    required Future<WatchLocalSubtitleResult> Function() onPressed,
  }) {
    if (widget.television) {
      return TvButton(
        key: key,
        unfocusedColor: Colors.transparent,
        onPressed: _busy ? null : (_) => _run(onPressed),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Text(label),
        ),
      );
    }
    return ListTile(
      key: key,
      enabled: !_busy,
      leading: Icon(icon),
      title: Text(label),
      subtitle: fileName == null
          ? null
          : Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: _busy ? null : () => _run(onPressed),
    );
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final locals = AppLocalizations.of(context)!;
    final fileName = video.localSubtitleName;
    final message = switch (_result) {
      WatchLocalSubtitleResult.invalidFile => locals.localSubtitleInvalidFile,
      WatchLocalSubtitleResult.unavailable => locals.localSubtitleUnavailable,
      _ => null,
    };
    final actions = [
      _action(
        key: const ValueKey('player-local-subtitle-pick'),
        icon: fileName == null ? Icons.attach_file : Icons.link,
        label: fileName == null
            ? locals.localSubtitleAttach
            : locals.localSubtitleRelink,
        fileName: fileName,
        onPressed: video.pickLocalSubtitle,
      ),
      if (fileName != null)
        _action(
          key: const ValueKey('player-local-subtitle-remove'),
          icon: Icons.link_off,
          label: locals.localSubtitleRemove,
          onPressed: video.removeLocalSubtitle,
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.television) ...[
          if (fileName != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child:
                  Text(fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          Wrap(alignment: WrapAlignment.center, children: actions),
        ] else
          ...actions,
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: LinearProgressIndicator(),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(message, textAlign: TextAlign.center),
            ),
          ),
      ],
    );
  }
}
