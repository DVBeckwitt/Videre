import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';

class PlayButton extends StatelessWidget {
  final bool hasAudio;
  final Function(bool isAudio) onPressed;
  final IconData? icon;
  final bool watchStyle;

  const PlayButton(
      {super.key,
      required this.onPressed,
      this.icon,
      this.hasAudio = true,
      this.watchStyle = false});

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (hasAudio)
          Padding(
            padding: const EdgeInsets.only(left: 100.0, top: 60),
            child: IconButton(
              onPressed: () {
                onPressed(true);
                AutoRouter.of(context).maybePop();
              },
              style: ButtonStyle(
                  backgroundColor: WidgetStateProperty.resolveWith((states) =>
                      watchStyle ? Colors.black54 : colorScheme.primary)),
              icon: Icon(
                Icons.music_note,
                size: watchStyle ? 24 : 35,
              ),
              color: watchStyle ? Colors.white : colorScheme.primaryContainer,
            ),
          ),
        IconButton(
          onPressed: () {
            onPressed(false);
            AutoRouter.of(context).maybePop();
          },
          style: ButtonStyle(
              backgroundColor: WidgetStateColor.resolveWith((states) =>
                  watchStyle ? Colors.black54 : colorScheme.primaryContainer)),
          icon: Icon(
            icon ?? Icons.play_arrow,
            size: watchStyle ? 46 : 75,
          ),
          color: watchStyle ? Colors.white : colorScheme.primary,
        ),
      ],
    );
  }
}
