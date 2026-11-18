import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_linkify/flutter_linkify.dart';

import '../../app/states/app.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../network/content_link.dart';
import '../../network/youtube_privacy.dart';
import '../../settings/models/db/server.dart';

/// Keep links supplied by descriptions and comments safe to copy and share.
/// The original address is used only as an input to Videre's internal router.
class InvidiousLinkifier extends Linkifier {
  final Server? server;
  final String unavailableLabel;

  const InvidiousLinkifier(this.server, this.unavailableLabel);

  static InvidiousLinkifier of(BuildContext context) {
    final serverUrl = context.select<AppCubit?, String?>((app) {
      final state = app?.state;
      if (state == null ||
          state.globalLoading ||
          state.sessionRecoveryRequired) {
        return null;
      }
      return state.server?.url;
    });
    return InvidiousLinkifier(
        serverUrl == null ? null : Server(url: serverUrl),
        AppLocalizations.of(context)?.contentLinkUnavailable ??
            '[Link unavailable]');
  }

  @override
  List<LinkifyElement> parse(
      List<LinkifyElement> elements, LinkifyOptions options) {
    return [
      for (final element in const UrlLinkifier().parse([
        for (final element in elements)
          if (element is TextElement)
            ..._extractOfficialLinks(element)
          else
            element,
      ], options))
        if (element is UrlElement) _rewrite(element) else element,
    ];
  }

  UrlElement _rewrite(UrlElement element) {
    final uri = Uri.tryParse(element.url);
    if (uri == null || !isOfficialYoutubeUrl(uri)) return element;
    final link = ContentLink.parse(uri);
    final selected = server;
    var label = unavailableLabel;
    if (link != null && selected != null) {
      try {
        label = link.invidiousUrl(selected).toString();
      } on FormatException {
        // No valid selected instance. Leave the direct address out of the text.
      }
    }
    return UrlElement(element.url, label, label);
  }

  Iterable<LinkifyElement> _extractOfficialLinks(TextElement element) sync* {
    var start = 0;
    for (final address in ContentLink.webAddressesIn(element.text)) {
      if (!isOfficialYoutubeUrl(address.uri)) continue;
      if (address.start > start) {
        yield TextElement(element.text.substring(start, address.start));
      }
      yield UrlElement(address.uri.toString());
      start = address.end;
    }
    if (start < element.text.length) {
      yield TextElement(element.text.substring(start));
    }
  }

  String rewriteText(String text) =>
      parse([TextElement(text)], const LinkifyOptions(humanize: false))
          .map((element) => element.text)
          .join();
}
