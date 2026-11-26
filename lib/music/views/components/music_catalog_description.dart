import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/models/invidious_linkifier.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/components/text_linkified.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';

class MusicCatalogDescription extends StatefulWidget {
  const MusicCatalogDescription({
    super.key,
    required this.title,
    required this.text,
    this.linkify = false,
  }) : _expanded = false;

  MusicCatalogDescription._expanded(MusicCatalogDescription description)
      : title = description.title,
        text = description.text,
        linkify = description.linkify,
        _expanded = true;

  final String title;
  final String text;
  final bool linkify;
  final bool _expanded;

  @override
  State<MusicCatalogDescription> createState() =>
      _MusicCatalogDescriptionState();
}

class _MusicCatalogDescriptionState extends State<MusicCatalogDescription> {
  final _recognizers = <String, TapGestureRecognizer>{};

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void didUpdateWidget(MusicCatalogDescription oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text || widget.linkify != oldWidget.linkify) {
      _disposeRecognizers();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _openUrl(String url) {
    openLinkifiedUrl(
      context,
      url,
      // Close About before an in-app push so Back returns to the artist.
      beforeOpeningInApp:
          widget._expanded ? () => Navigator.of(context).pop() : null,
    );
  }

  TextSpan _descriptionSpan(BuildContext context) {
    if (!widget.linkify) return TextSpan(text: widget.text);

    final elements = InvidiousLinkifier.of(
      context,
    ).parse([TextElement(widget.text)], textLinkifyOptions);
    final linkStyle = TextStyle(color: Theme.of(context).colorScheme.primary);
    return TextSpan(
      children: [
        for (final element in elements)
          if (element is UrlElement)
            TextSpan(
              text: element.text,
              style: linkStyle,
              mouseCursor: SystemMouseCursors.click,
              recognizer: _recognizers.putIfAbsent(
                element.url,
                () =>
                    TapGestureRecognizer()..onTap = () => _openUrl(element.url),
              ),
            )
          else
            TextSpan(text: element.text),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final span = _descriptionSpan(context);
    if (widget._expanded) return Text.rich(span);

    return LayoutBuilder(
      builder: (context, constraints) {
        const lines = 6;
        final defaults = DefaultTextStyle.of(context);
        final style = MediaQuery.boldTextOf(context)
            ? defaults.style.copyWith(fontWeight: FontWeight.bold)
            : defaults.style;
        final preview = TextPainter(
          text: TextSpan(style: style, children: [span]),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          textHeightBehavior: defaults.textHeightBehavior ??
              DefaultTextHeightBehavior.maybeOf(context),
          maxLines: lines,
          ellipsis: '\u2026',
        )..layout(maxWidth: constraints.maxWidth);
        final truncated = preview.didExceedMaxLines;
        preview.dispose();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(span, maxLines: lines, overflow: TextOverflow.ellipsis),
            if (truncated)
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  animationStyle: AppMotion.dialogStyle(context),
                  builder: (context) => AlertDialog(
                    title: Text(widget.title),
                    scrollable: true,
                    content: MusicCatalogDescription._expanded(widget),
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
}
