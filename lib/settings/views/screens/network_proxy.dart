import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:flutter/material.dart';

class NetworkProxySettingsScreen extends StatefulWidget {
  final SocksProxyConfig? initialConfig;
  final Future<void> Function(SocksProxyConfig)? onApply;
  final Future<void> Function(SocksProxyConfig)? onTest;

  const NetworkProxySettingsScreen({
    super.key,
    this.initialConfig,
    this.onApply,
    this.onTest,
  });

  @override
  State<NetworkProxySettingsScreen> createState() =>
      _NetworkProxySettingsScreenState();
}

class _NetworkProxySettingsScreenState
    extends State<NetworkProxySettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late SocksProxyConfig _savedConfig;
  late bool _enabled;
  bool _busy = false;
  String? _status;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig ?? NetworkProxy.instance.config;
    _savedConfig = config;
    _enabled = config.enabled;
    _host = TextEditingController(text: config.host);
    _port = TextEditingController(text: '${config.port}');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _clearStatus() => setState(() => _status = null);

  void _useOrbot() {
    setState(() {
      _enabled = true;
      _host.text = '127.0.0.1';
      _port.text = '9050';
      _status = null;
    });
  }

  Future<void> _run({required bool testing}) async {
    if (!_formKey.currentState!.validate()) return;
    final locals = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final config = _enabled
          ? SocksProxyConfig(
              enabled: true,
              host: _host.text.trim(),
              port: int.parse(_port.text),
            )
          : SocksProxyConfig(
              host: _savedConfig.host,
              port: _savedConfig.port,
            );
      if (testing) {
        await (widget.onTest ?? NetworkProxy.instance.test)(config);
      } else {
        await (widget.onApply ?? NetworkProxy.instance.apply)(config);
        _savedConfig = config;
      }
      if (!mounted) return;
      setState(() {
        _failed = false;
        _status = testing
            ? locals.networkProxyTestSucceeded
            : locals.networkProxySaved;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _status = error is ProxyTestNeedsServer
            ? locals.networkProxyTestNeedsServer
            : testing
                ? locals.networkProxyTestFailed
                : locals.networkProxySaveFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(locals.networkProxy)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(locals.networkProxyDescription),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    autofocus: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(locals.networkProxyEnable),
                    value: _enabled,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                              _enabled = value;
                              _status = null;
                            }),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _host,
                    enabled: !_busy && _enabled,
                    decoration:
                        InputDecoration(labelText: locals.networkProxyHost),
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => _clearStatus(),
                    validator: (value) {
                      if (!_enabled) return null;
                      try {
                        SocksProxyConfig(host: value?.trim() ?? '');
                        return null;
                      } on FormatException {
                        return locals.networkProxyInvalidHost;
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _port,
                    enabled: !_busy && _enabled,
                    decoration:
                        InputDecoration(labelText: locals.networkProxyPort),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => _clearStatus(),
                    validator: (value) {
                      if (!_enabled) return null;
                      final port = int.tryParse(value ?? '');
                      return port == null || port < 1 || port > 65535
                          ? locals.networkProxyInvalidPort
                          : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _useOrbot,
                      icon: const Icon(Icons.settings_suggest_outlined),
                      label: Text(locals.networkProxyOrbotPreset),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(locals.networkProxyOrbotHelp),
                  const SizedBox(height: 16),
                  Text(locals.networkProxyExceptions),
                  const SizedBox(height: 12),
                  Text(locals.networkProxyApplyHelp),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 16,
                    runSpacing: 12,
                    children: [
                      OutlinedButton(
                        onPressed: _busy || !_enabled
                            ? null
                            : () => _run(testing: true),
                        child: Text(locals.testConnection),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : () => _run(testing: false),
                        child: Text(locals.save),
                      ),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  if (_status != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(_status!,
                          style:
                              TextStyle(color: _failed ? colors.error : null)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
