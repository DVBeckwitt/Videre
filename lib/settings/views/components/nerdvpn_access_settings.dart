import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart';
import '../../../network/nerdvpn_access.dart';
import '../../../router.dart';
import '../../../utils/motion.dart';
import '../../models/db/server.dart';
import 'nerdvpn_onion_setup.dart';

class NerdVpnAccessSettings extends StatefulWidget {
  final Server account;
  final bool authenticating;
  final Future<void> Function() onCheck;
  final Future<void> Function(String key) onSaveKey;

  const NerdVpnAccessSettings({
    super.key,
    required this.account,
    required this.authenticating,
    required this.onCheck,
    required this.onSaveKey,
  });

  @override
  State<NerdVpnAccessSettings> createState() => _NerdVpnAccessSettingsState();
}

class _NerdVpnAccessSettingsState extends State<NerdVpnAccessSettings> {
  late Future<NerdVpnAccessStatus> _status;
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _status = NerdVpnAccess.instance.status(widget.account);
  }

  @override
  void didUpdateWidget(NerdVpnAccessSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account != widget.account ||
        (oldWidget.authenticating && !widget.authenticating)) {
      _status = NerdVpnAccess.instance.status(widget.account);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || widget.authenticating) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = NerdVpnAccess.instance.status(widget.account);
        });
      }
    }
  }

  Future<void> _preferences() async {
    final account = widget.account;
    if (isNerdVpnOnionUrl(account.url)) {
      await openNerdVpnTorPreferences(context, account.url,
          isCurrent: () => mounted && widget.account == account);
      return;
    }
    final url = Uri.parse(account.url)
        .replace(path: '/preferences', fragment: 'api-access');
    final onion = url.host.endsWith('.onion');
    try {
      if (!onion &&
          !isTv &&
          await launchUrl(url, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // A TV or a device without a browser can show the address instead.
    }
    if (!mounted || widget.account != account) return;
    final locals = AppLocalizations.of(context)!;
    await showDialog<void>(
        context: context,
        animationStyle: AppMotion.dialogStyle(context),
        builder: (context) => AlertDialog(
              title: Text(locals.nerdVpnPreferences),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (onion) ...[
                      Text(locals.nerdVpnOnionPreferencesHelp),
                      const SizedBox(height: 12),
                    ],
                    SelectableText(url.toString()),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(locals.ok)),
              ],
            ));
  }

  Future<void> _enterKey() async {
    final account = widget.account;
    final saveKey = widget.onSaveKey;
    var enteredKey = '';
    final locals = AppLocalizations.of(context)!;
    final form = GlobalKey<FormState>();
    final key = await showDialog<String>(
        context: context,
        animationStyle: AppMotion.dialogStyle(context),
        builder: (context) => AlertDialog(
              title: Text(locals.nerdVpnManualKey),
              content: Form(
                key: form,
                child: TextFormField(
                  onChanged: (value) => enteredKey = value,
                  autofocus: true,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  maxLength: 37,
                  decoration: const InputDecoration(hintText: 'nvpn_…'),
                  validator: (value) => NerdVpnAccess.isValidKey(value ?? '')
                      ? null
                      : locals.nerdVpnKeyInvalid,
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(locals.cancel)),
                TextButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        Navigator.of(context).pop(enteredKey.trim());
                      }
                    },
                    child: Text(locals.ok)),
              ],
            ));
    if (key != null && mounted && widget.account == account) {
      await _run(() => saveKey(key));
    }
  }

  String _description(NerdVpnAccessStatus status, AppLocalizations locals) {
    switch (status.state) {
      case 'ready':
        return locals.nerdVpnAccessReady;
      case 'waiting':
        final date = status.availableAt;
        return date == null
            ? locals.nerdVpnAccessWaitingUnknown
            : locals.nerdVpnAccessWaiting(_date(date));
      case 'disabled':
        return locals.nerdVpnAccessDisabled;
      case 'denied':
        return locals.nerdVpnAccessDenied;
      case 'proxyRequired':
        return locals.nerdVpnProxyRequired;
      case 'unavailable':
        return locals.nerdVpnAccessUnavailable;
      default:
        return isNerdVpnOnionUrl(widget.account.url)
            ? locals.nerdVpnOnionSetup
            : locals.nerdVpnAccessSignIn;
    }
  }

  String _date(DateTime value) =>
      DateFormat.yMMMd(Localizations.localeOf(context).toLanguageTag())
          .add_jm()
          .format(value.toLocal());

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final busy = _busy || widget.authenticating;
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<NerdVpnAccessStatus>(
          future: _status,
          builder: (context, snapshot) {
            final status = snapshot.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    status?.state == 'waiting'
                        ? locals.nerdVpnApprovalPending
                        : locals.nerdVpnAccessTitle,
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (snapshot.hasError || _failed)
                  Text(locals.accountActionFailed),
                if (!snapshot.hasError && status != null)
                  Text(_description(status, locals)),
                if (status?.retryAt != null)
                  Text(locals.nerdVpnAccessRetryAt(_date(status!.retryAt!))),
                if (busy || snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => _run(widget.onCheck),
                      child: Text(status?.state == 'waiting'
                          ? locals.nerdVpnCheckEligibility
                          : locals.nerdVpnCheckAccess),
                    ),
                    TextButton(
                        onPressed: busy ? null : _preferences,
                        child: Text(locals.nerdVpnPreferences)),
                    TextButton(
                        onPressed: busy ? null : _enterKey,
                        child: Text(locals.nerdVpnManualKey)),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => AutoRouter.of(context).push(isTv
                              ? const TvSettingsManageServersRoute()
                              : const ManageServersRoute()),
                      child: Text(locals.chooseInstance),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
