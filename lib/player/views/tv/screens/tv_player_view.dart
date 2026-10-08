import 'package:auto_route/annotations.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/video_player.dart';
import 'package:clipious/player/views/components/remote_control.dart';
import 'package:clipious/settings/states/settings.dart';

import '../../../../main.dart';

@RoutePage()
class TvPlayerScreen extends StatefulWidget {
  final List<Video> videos;
  final bool resumeSession;
  final Duration? startAt;
  final bool receiveRemote;

  const TvPlayerScreen(
      {super.key,
      required this.videos,
      this.resumeSession = false,
      this.startAt,
      this.receiveRemote = false});

  @override
  State<TvPlayerScreen> createState() => _TvPlayerScreenState();
}

class _TvPlayerScreenState extends State<TvPlayerScreen> {
  bool _openedReceiver = false;

  @override
  Widget build(BuildContext context) {
    var settings = context.read<SettingsCubit>();
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => PlayerCubit(
              PlayerState.init(widget.videos).copyWith(startAt: widget.startAt),
              settings,
              resume: widget.resumeSession),
        )
      ],
      child: Theme(
        data: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
        child: Scaffold(
          body: BlocBuilder<PlayerCubit, PlayerState>(
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
              return Stack(
                children: [
                  if (state.hasVideo)
                    VideoPlayer(
                      video: state.currentlyPlaying,
                      offlineVideo: state.offlineCurrentlyPlaying,
                      startAt: state.startAt,
                      miniPlayer: false,
                      playNow: true,
                      disableControls: true,
                    ),
                  if (!state.hasVideo)
                    Center(
                        child: RemoteControlButton(
                            player: context.read<PlayerCubit>())),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
