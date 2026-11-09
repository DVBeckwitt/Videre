import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../network/nerdvpn_access.dart';
import '../../../network/tor_browser.dart';
import '../../../utils/motion.dart';
import '../../../utils/views/tv/components/tv_text_field.dart';

Future<void> openNerdVpnTorPreferences(BuildContext context, String serverUrl,
    {bool Function()? isCurrent}) async {
  if (!NerdVpnAccess.supportsUrl(serverUrl) || !isNerdVpnOnionUrl(serverUrl)) {
    return;
  }
  try {
    if (await TorBrowser.instance.openNerdVpnPreferences(serverUrl)) return;
  } catch (_) {
    // Show the same safe handoff guidance if the platform cannot open the app.
  }
  if (!context.mounted || isCurrent?.call() == false) return;
  final locals = AppLocalizations.of(context)!;
  final url = Uri.parse(serverUrl)
      .replace(path: '/preferences', fragment: 'api-access');
  var opening = false;
  String? failure;
  await showDialog<void>(
    context: context,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) => StatefulBuilder(builder: (context, update) {
      final dialogRoute = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      // Dismissed dialogs stay mounted until their reverse animation finishes.
      bool dialogIsCurrent() =>
          context.mounted && dialogRoute?.isCurrent == true;
      return AlertDialog(
        title: Text(locals.nerdVpnOpenTorBrowser),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(locals.nerdVpnTorBrowserHandoff),
              const SizedBox(height: 12),
              SelectableText(url.toString()),
              if (failure != null) ...[
                const SizedBox(height: 12),
                Text(failure!),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: opening
                ? null
                : () async {
                    if (!dialogIsCurrent()) return;
                    if (isCurrent?.call() == false) {
                      navigator.pop();
                      return;
                    }
                    update(() {
                      opening = true;
                      failure = null;
                    });
                    try {
                      await Clipboard.setData(
                          ClipboardData(text: url.toString()));
                    } catch (_) {
                      if (dialogIsCurrent() && isCurrent?.call() != false) {
                        update(() {
                          opening = false;
                          failure = locals.nerdVpnTorCopyFailed;
                        });
                      }
                      return;
                    }
                    if (!dialogIsCurrent() || isCurrent?.call() == false) {
                      return;
                    }
                    final opened = await TorBrowser.instance.openApp();
                    if (!dialogIsCurrent() || isCurrent?.call() == false) {
                      return;
                    }
                    if (opened) {
                      navigator.pop();
                    } else {
                      update(() {
                        opening = false;
                        failure = locals.nerdVpnTorBrowserUnavailable;
                      });
                    }
                  },
            child: Text(locals.nerdVpnTorCopyAndOpen),
          ),
          TextButton(
            onPressed: () {
              if (dialogIsCurrent()) navigator.pop();
            },
            child: Text(locals.ok),
          ),
        ],
      );
    }),
  );
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
              icon: const Icon(Icons.open_in_new),
              label: Text(locals.nerdVpnOpenTorBrowser),
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
