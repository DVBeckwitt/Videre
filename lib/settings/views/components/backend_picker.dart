import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/services/backend_discovery.dart';
import 'package:clipious/settings/services/backend_browser.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String backendLabel(BuildContext context, Server server) {
  final locals = AppLocalizations.of(context)!;
  final selector = server.backendSelector;
  if (selector == null) return locals.backendCheckAvailable;
  final value = selector.selectedValue(server);
  if (value == null) return locals.backendDefault;
  for (final option in selector.options) {
    if (option.value == value) return option.label;
  }
  return locals.backendCustom;
}

Future<void> showBackendPicker(
  BuildContext context, {
  required Server server,
  required Future<Server> Function() onDiscover,
  required Future<void> Function(String?, bool) onSave,
  Future<Server> Function(Uri, String)? onDiscoverFromPage,
}) =>
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: false,
      builder: (_) => BackendPicker(
        server: server,
        onDiscover: onDiscover,
        onSave: onSave,
        onBrowserDiscover:
            onDiscoverFromPage == null || !BackendBrowser.supports(server)
                ? null
                : () async {
                    final page = await BackendBrowser.open(
                        server, AppLocalizations.of(context)!);
                    if (page == null) return null;
                    return onDiscoverFromPage(page.uri, page.source);
                  },
      ),
    );

class BackendPicker extends StatefulWidget {
  final Server server;
  final Future<Server> Function() onDiscover;
  final Future<void> Function(String?, bool) onSave;
  final Future<Server?> Function()? onBrowserDiscover;

  const BackendPicker({
    super.key,
    required this.server,
    required this.onDiscover,
    required this.onSave,
    this.onBrowserDiscover,
  });

  @override
  State<BackendPicker> createState() => _BackendPickerState();
}

enum _DiscoveryFailure { unsupported, unavailable, proxyUnsupported }

class _BackendPickerState extends State<BackendPicker> {
  late Server _server = widget.server;
  late String? _initialValue = _server.backendSelector?.selectedValue(_server);
  late String? _value = _initialValue;
  late bool _initialAutomatic =
      _server.backendSelector?.automaticFallback ?? false;
  late bool _automatic = _initialAutomatic;
  bool _saving = false;
  bool _discovering = false;
  bool _saveFailed = false;
  _DiscoveryFailure? _discoveryFailure;
  final _errorKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (_server.backendSelector == null) _discover();
  }

  bool get _busy => _saving || _discovering;

  bool _knownValue(String? value) =>
      value == null ||
      (_server.backendSelector?.options
              .any((option) => option.value == value) ??
          false);

  void _reveal(BuildContext target) {
    Scrollable.ensureVisible(target,
        duration: const Duration(milliseconds: 150),
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
  }

  void _revealError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final errorContext = _errorKey.currentContext;
      if (mounted && errorContext != null) _reveal(errorContext);
    });
  }

  Future<void> _discover({bool browser = false}) async {
    final previousFailure = _discoveryFailure;
    setState(() {
      _discovering = true;
      _discoveryFailure = null;
    });
    try {
      final discovered = browser
          ? await widget.onBrowserDiscover!()
          : await widget.onDiscover();
      if (!mounted) return;
      if (discovered == null) {
        setState(() {
          _discovering = false;
          _discoveryFailure = previousFailure;
        });
        return;
      }
      if (discovered.backendSelector == null) {
        setState(() {
          _discovering = false;
          _discoveryFailure = _DiscoveryFailure.unsupported;
        });
        _revealError();
        return;
      }
      setState(() {
        // Refreshing metadata must not replace unsaved choices in this dialog.
        if (_server.backendSelector == null) {
          _initialValue = discovered.backendSelector!.selectedValue(discovered);
          _value = _initialValue;
          _initialAutomatic = discovered.backendSelector!.automaticFallback;
          _automatic = _initialAutomatic;
        }
        _server = discovered;
        _discovering = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _discovering = false;
        _discoveryFailure = switch (error) {
          BackendDiscoveryUnsupported() => _DiscoveryFailure.unsupported,
          BackendBrowserProxyUnsupported() =>
            _DiscoveryFailure.proxyUnsupported,
          _ => _DiscoveryFailure.unavailable,
        };
      });
      _revealError();
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveFailed = false;
    });
    try {
      await widget.onSave(_value, _automatic);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveFailed = true;
      });
      _revealError();
    }
  }

  Widget _choice(String? value, String label,
      {bool enabled = true, bool autofocus = false}) {
    final selected = _value == value;
    return MergeSemantics(
      child: Semantics(
        checked: selected,
        inMutuallyExclusiveGroup: true,
        child: Builder(
            builder: (tileContext) => ListTile(
                  key: ValueKey('backend-${value ?? 'default'}'),
                  autofocus: autofocus,
                  onFocusChange: (focused) {
                    if (focused) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (tileContext.mounted) _reveal(tileContext);
                      });
                    }
                  },
                  enabled: enabled && !_busy,
                  selected: selected,
                  leading: ExcludeSemantics(
                    child: Icon(selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked),
                  ),
                  title: Text(label),
                  onTap: !enabled || _busy
                      ? null
                      : () => setState(() {
                            _value = value;
                            _saveFailed = false;
                          }),
                )),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final selector = _server.backendSelector;
    final isCustom = !_knownValue(_value);
    final canSave = selector != null &&
        !isCustom &&
        !_busy &&
        (_value != _initialValue || _automatic != _initialAutomatic);
    final error = _saveFailed
        ? locals.backendSaveFailed
        : switch (_discoveryFailure) {
            _DiscoveryFailure.unsupported => locals.backendUnsupported,
            _DiscoveryFailure.unavailable => locals.backendDiscoveryFailed,
            _DiscoveryFailure.proxyUnsupported =>
              locals.backendBrowserProxyUnsupported,
            null => null,
          };
    return PopScope(
      canPop: !_saving,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          scrollable: true,
          title: Text(locals.backend),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(locals.backendHelp),
                const SizedBox(height: 12),
                if (_discovering)
                  Semantics(
                    liveRegion: true,
                    child: Column(children: [
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(locals.backendChecking),
                    ]),
                  ),
                if (selector != null) ...[
                  _choice(null, locals.backendDefault,
                      autofocus: _initialValue == null || isCustom),
                  if (isCustom)
                    _choice(_value, locals.backendCustom, enabled: false),
                  for (final option in selector.options)
                    _choice(option.value, option.label,
                        autofocus: option.value == _initialValue),
                  const Divider(),
                  SwitchListTile(
                    key: const ValueKey('backend-automatic'),
                    title: Text(locals.backendAutomatic),
                    subtitle: Text(locals.backendAutomaticHelp),
                    value: _automatic,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                              _automatic = value;
                              _saveFailed = false;
                            }),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('backend-refresh'),
                    onPressed: _busy ? null : _discover,
                    icon: const Icon(Icons.refresh),
                    label: Text(locals.backendRefresh),
                  ),
                ],
                if (error != null)
                  Semantics(
                    key: _errorKey,
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(error,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error)),
                          if (_discoveryFailure != null &&
                              widget.onBrowserDiscover != null) ...[
                            const SizedBox(height: 8),
                            Text(NetworkProxy.instance.config.enabled
                                ? locals.backendBrowserProxyHelp
                                : locals.backendBrowserHelp),
                            OutlinedButton.icon(
                              key: const ValueKey('backend-browser'),
                              onPressed:
                                  _busy ? null : () => _discover(browser: true),
                              icon: const Icon(Icons.language),
                              label: Text(locals.backendBrowserOpen),
                            ),
                          ],
                          if (_discoveryFailure != null)
                            TextButton(
                              key: const ValueKey('backend-retry'),
                              autofocus: selector == null,
                              onPressed: _busy ? null : _discover,
                              child: Text(locals.retry),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('backend-cancel'),
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: Text(locals.cancel),
            ),
            if (selector != null)
              FilledButton(
                key: const ValueKey('backend-save'),
                onPressed: canSave ? _save : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_saving) ...[
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(locals.save),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
