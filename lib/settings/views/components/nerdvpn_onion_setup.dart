import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../network/nerdvpn_access.dart';
import '../../../utils/views/components/external_link.dart';
import '../../../utils/views/tv/components/tv_text_field.dart';

Future<void> openNerdVpnTorPreferences(BuildContext context, String serverUrl,
    {bool Function()? isCurrent}) async {
  if (!NerdVpnAccess.supportsUrl(serverUrl) ||
      !isNerdVpnOnionUrl(serverUrl) ||
      !context.mounted ||
      isCurrent?.call() == false) {
    return;
  }
  final locals = AppLocalizations.of(context)!;
  final url = Uri.parse(serverUrl)
      .replace(path: '/preferences', fragment: 'api-access');
  await openExternalLink(context, url,
      title: locals.nerdVpnTorAddress,
      help: locals.nerdVpnTorBrowserHandoff,
      isCurrent: isCurrent);
}

class NerdVpnOnionSetup extends StatefulWidget {
  final String serverUrl;
  final TextEditingController apiKeyController;
  final bool loading;
  final bool television;

  const NerdVpnOnionSetup({
    super.key,
    required this.serverUrl,
    required this.apiKeyController,
    required this.loading,
    this.television = false,
  });

  @override
  State<NerdVpnOnionSetup> createState() => _NerdVpnOnionSetupState();
}

class _NerdVpnOnionSetupState extends State<NerdVpnOnionSetup> {
  bool _opening = false;

  Future<void> _openBrowser() async {
    if (_opening || widget.loading) return;
    final origin = widget.serverUrl;
    setState(() => _opening = true);
    try {
      await openNerdVpnTorPreferences(context, origin,
          isCurrent: () => mounted && widget.serverUrl == origin);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final decoration = InputDecoration(
      label: Text(locals.nerdVpnManualKey),
      hintText: 'nvpn_…',
    );
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(locals.nerdVpnOnionSetupSteps),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: widget.loading || _opening ? null : _openBrowser,
              icon: const Icon(Icons.content_copy),
              label: Text(locals.nerdVpnTorAddress),
            ),
            const SizedBox(height: 8),
            if (widget.television)
              ExcludeFocus(
                excluding: widget.loading,
                child: TvTextField(
                  controller: widget.apiKeyController,
                  decoration: decoration,
                  obscureText: true,
                  autocorrect: false,
                  keyboardType: TextInputType.visiblePassword,
                ),
              )
            else
              TextField(
                controller: widget.apiKeyController,
                readOnly: widget.loading,
                decoration: decoration,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                keyboardType: TextInputType.visiblePassword,
              ),
            const SizedBox(height: 8),
            Text(locals.nerdVpnOnionKeyHelp,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
