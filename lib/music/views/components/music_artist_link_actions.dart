import 'package:clipious/app/states/app.dart';
import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils.dart' show showSharingSheet;
import 'package:clipious/utils/models/sharelink.dart';
import 'package:clipious/utils/views/components/external_link.dart';
import 'package:flutter/material.dart';

class MusicArtistLinkActions extends StatelessWidget {
  const MusicArtistLinkActions({
    super.key,
    required this.artistId,
    required this.session,
    required this.isCurrent,
  });

  final String artistId;
  final AppState session;
  final bool Function() isCurrent;

  @override
  Widget build(BuildContext context) {
    final channelId = normalizeChannelId(artistId);
    final server = session.server;
    if (channelId == null || server == null) return const SizedBox.shrink();

    final locals = AppLocalizations.of(context)!;
    final links = ChannelShareLinks(channelId);
    final database = db;

    bool current() {
      if (!context.mounted ||
          !isCurrent() ||
          !identical(db, database) ||
          database.profileId != session.profileId ||
          server.profileId != session.profileId) {
        return false;
      }
      final selected =
          database.forProfile(session.profileId).getAccount(server.accountId);
      return selected?.inUse == true && selected?.url == server.url;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: locals.share,
          onPressed: () => showSharingSheet(context, links, isCurrent: current),
          icon: const Icon(Icons.share_outlined),
        ),
        IconButton(
          tooltip: locals.openExternally,
          onPressed: () async {
            if (!current()) return;
            final Uri link;
            try {
              link = links.getInvidiousLink(server, null);
            } on FormatException {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(locals.externalLinkBlocked)),
              );
              return;
            }
            await openExternalLink(context, link, isCurrent: current);
          },
          icon: const Icon(Icons.open_in_new),
        ),
      ],
    );
  }
}
