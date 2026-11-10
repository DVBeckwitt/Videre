import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../network/tor_browser.dart';
import '../../../network/youtube_privacy.dart';
import '../../motion.dart';

bool isPermittedExternalLink(Uri url) =>
    const {'http', 'https'}.contains(url.scheme) &&
    url.hasAuthority &&
    url.host.isNotEmpty &&
    url.userInfo.isEmpty &&
    !url.authority.contains('@') &&
    !isOfficialYoutubeUrl(url);

/// External applications do not inherit Videre's connection policy. Show an
/// address for an explicit copy action, never launch a browser or another app.
/// Even a currently safe address could redirect after an external handoff.
Future<void> openExternalLink(BuildContext context, Uri url,
    {String? title, String? help, bool Function()? isCurrent}) async {
  if (!context.mounted || isCurrent?.call() == false) return;
  final locals = AppLocalizations.of(context)!;
  if (!isPermittedExternalLink(url)) {
    await showDialog<void>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        content: Text(locals.externalLinkBlocked),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(locals.ok)),
        ],
      ),
    );
    return;
  }
  final onion = TorBrowser.isOnionAddress(url);
  final address = url.toString();
  var copying = false;
  String? result;
  await showDialog<void>(
    context: context,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => StatefulBuilder(builder: (context, update) {
      final route = ModalRoute.of(context);
      bool current() =>
          context.mounted &&
          route?.isCurrent == true &&
          isCurrent?.call() != false;
      return AlertDialog(
        title: Text(title ?? locals.externalLinkTitle),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(help ??
                (onion
                    ? locals.torBrowserLinkHandoff
                    : locals.externalLinkCopyHelp)),
            const SizedBox(height: 12),
            SelectableText(address),
            if (result != null) ...[
              const SizedBox(height: 12),
              Text(result!),
            ],
          ]),
        ),
        actions: [
          TextButton(
            onPressed: copying
                ? null
                : () async {
                    if (!current()) return;
                    update(() {
                      copying = true;
                      result = null;
                    });
                    try {
                      await Clipboard.setData(ClipboardData(text: address));
                      if (!current()) return;
                      update(() {
                        copying = false;
                        result = locals.externalLinkCopied;
                      });
                    } catch (_) {
                      if (!current()) return;
                      update(() {
                        copying = false;
                        result = locals.externalLinkCopyFailed;
                      });
                    }
                  },
            child: Text(locals.copyToClipBoard),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.ok),
          ),
        ],
      );
    }),
  );
}
