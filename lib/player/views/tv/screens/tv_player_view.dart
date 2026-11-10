import 'package:auto_route/annotations.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/video_retry_notice.dart';
import 'package:clipious/player/views/components/video_player.dart';
import 'package:clipious/player/views/components/remote_control.dart';
import 'package:clipious/settings/states/settings.dart';

import '../../../../main.dart';
import '../../../../music/views/screens/music.dart';
import '../../../../playlists/models/playlist_reference.dart';
import '../../../../playlists/services/playlist_load_session.dart';

@RoutePage()
class TvPlayerScreen extends StatefulWidget {
  final List<Video> videos;
  final bool resumeSession;
  final Duration? startAt;
  final bool receiveRemote;
  final PlaylistReference? playlistReference;
  final PlaylistLoadSession? playlistLoader;
  final int startIndex;
  final bool? audio;

  const TvPlayerScreen(
      {super.key,
      required this.videos,
      this.resumeSession = false,
      this.startAt,
      this.playlistReference,
      this.playlistLoader,
      this.startIndex = 0,
      this.audio,
      this.receiveRemote = false});

  @override
  State<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends State<TvPlayerScreen> {
  bool _openedReceiver = false;

  @override
  Widget build(BuildContext context) {
    var settings = context.read<SettingsCubit>();
    return BlocProvider(
      create: (context) => PlayerCubit(
          PlayerState.init(widget.videos).copyWith(startAt: widget.startAt),
          settings,
          resume: widget.resumeSession,
          playlistReference: widget.playlistReference,
          playlistLoader: widget.playlistLoader,
          startIndex: widget.startIndex,
          playlistAudio: widget.audio),
      child: Theme(
        data: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
        child: Shortcuts(
          shortcuts: {
            LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          },
          child: Scaffold(
            body: Stack(
              fit: StackFit.passthrough,
              children: [
                BlocBuilder<PlayerCubit, PlayerState>(
                  builder: (context, state) {
                    if (widget.receiveRemote && !_openedReceiver) {
                      _openedReceiver = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted)
                          RemoteControlButton.show(
                              context, context.read<PlayerCubit>(),
                              startReceiving: true);
                      });
                    }
                    if (!state.hasVideo) {
                      return Center(
                          child: RemoteControlButton(
                              player: context.read<PlayerCubit>()));
                    }
                    return SizedBox.expand(
                      child: state.isAudio
                          ? MusicScreen.tvAudio(
                              video: state.currentlyPlaying,
                              offlineVideo: state.offlineCurrentlyPlaying,
                            )
                          : VideoPlayer(
                              video: state.currentlyPlaying,
                              offlineVideo: state.offlineCurrentlyPlaying,
                              startAt: state.startAt,
                              miniPlayer: false,
                              playNow: true,
                              disableControls: true,
                            ),
                    );
                  },
                ),
                const Positioned.fill(child: PlayerRetryIndicator()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
