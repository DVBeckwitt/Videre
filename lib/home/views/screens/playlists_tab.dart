import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

@RoutePage()
class PlaylistsTab extends StatelessWidget {
  const PlaylistsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return HomeDataSource.playlist.build(context, false);
  }
}

@RoutePage()
class PlaylistLibraryScreen extends StatelessWidget {
  const PlaylistLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.playlists)),
      body: const SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: innerHorizontalPadding),
          child: PlaylistsTab(),
        ),
      ),
    );
  }
}
