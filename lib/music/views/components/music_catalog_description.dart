import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';

class MusicCatalogDescription extends StatelessWidget {
  const MusicCatalogDescription({
    super.key,
    required this.title,
    required this.text,
  });

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          const lines = 6;
          final style = DefaultTextStyle.of(context).style;
          final preview = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: lines,
          )..layout(maxWidth: constraints.maxWidth);
          final truncated = preview.didExceedMaxLines;
          preview.dispose();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, maxLines: lines, overflow: TextOverflow.ellipsis),
              if (truncated)
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    animationStyle: AppMotion.dialogStyle(context),
                    builder: (context) => AlertDialog(
                      title: Text(title),
                      scrollable: true,
                      content: Text(text),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            MaterialLocalizations.of(context).closeButtonLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  child: Text(AppLocalizations.of(context)!.about),
                ),
            ],
          );
        },
      );
}
