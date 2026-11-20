import 'package:flutter/material.dart';

import 'mini_player_controls.dart';

class ExpandedPlayerDetails extends StatelessWidget {
  final bool hasOnlineVideo;
  final Widget child;

  const ExpandedPlayerDetails({
    super.key,
    required this.hasOnlineVideo,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Column(children: [
        if (hasOnlineVideo)
          // Use the toolbar's natural height. In a shrinking player it can
          // scroll without taking all the space needed for the details.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight / 2),
            child: const SingleChildScrollView(
              child: MiniPlayerControls(directActions: true),
            ),
          )
        else
          const MiniPlayerControls(),
        Expanded(child: child),
      ]),
    );
  }
}
