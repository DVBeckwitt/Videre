import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/recommendations/recommendation_service.dart';
import 'package:flutter/material.dart';

Future<void> showMusicDismissalNotice(
  BuildContext context, {
  required RecommendationFeedback feedback,
  required UndoMusicDismissal undo,
  required bool Function() isCurrent,
  VoidCallback? onRestored,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final locals = AppLocalizations.of(context)!;
  messenger.removeCurrentSnackBar();
  final notice = messenger.showSnackBar(SnackBar(
    content: Text(feedback == RecommendationFeedback.block
        ? locals.musicRecommendationArtistBlocked
        : locals.musicRecommendationSongDismissed),
    action: SnackBarAction(
      label: locals.localMusicUndoHide,
      onPressed: () async {
        if (!isCurrent()) return;
        try {
          if (await undo() && isCurrent()) onRestored?.call();
        } catch (_) {
          if (context.mounted && isCurrent()) {
            showMusicRecommendationError(context);
          }
        }
      },
    ),
  ));
  await notice.closed;
}

void showMusicRecommendationError(BuildContext context) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.recommendationError)));
