import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../screens/music_offline.dart';

class BrowseOfflineMusicButton extends StatelessWidget {
  const BrowseOfflineMusicButton({super.key});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return FilledButton.tonalIcon(
      icon: const Icon(Icons.offline_bolt_outlined),
      label: Text(locals.musicBrowseOffline),
      onPressed: () {
        if (ModalRoute.isCurrentOf(context) == false) return;
        Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const OfflineMusicPage()),
        );
      },
    );
  }
}
