import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

bool isPastedLinkSourceActive(BuildContext context) =>
    context.mounted &&
    TickerMode.of(context) &&
    ModalRoute.of(context)?.isCurrent != false;

/// Returns true to open the content ID, false to search for the text, or null
/// when the user cancels.
Future<bool?> choosePastedLinkAction(BuildContext context) async {
  if (!isPastedLinkSourceActive(context)) return null;
  return showDialog<bool>(
    context: context,
    useRootNavigator: false,
    builder: (context) {
      final locals = AppLocalizations.of(context)!;
      return AlertDialog(
        scrollable: true,
        content: Text(locals.unfamiliarLinkPrompt),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(locals.searchAsText),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(locals.openOnCurrentInstance),
          ),
        ],
      );
    },
  );
}
