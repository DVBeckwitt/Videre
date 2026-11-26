import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:videre_proxy/videre_proxy.dart';

import '../../../downloads/states/download_manager.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../utils/motion.dart';

Future<void> showPlaybackCacheSettings(BuildContext context) {
  final player = context.read<PlayerCubit>();
  final downloads = context.read<DownloadManagerCubit?>();
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (context) =>
        _PlaybackCacheSettings(beforeChange: player.hide, downloads: downloads),
  );
}

class _PlaybackCacheSettings extends StatefulWidget {
  final VoidCallback beforeChange;
  final DownloadManagerCubit? downloads;
  const _PlaybackCacheSettings({required this.beforeChange, this.downloads});

  @override
  State<_PlaybackCacheSettings> createState() => _PlaybackCacheSettingsState();
}

class _PlaybackCacheSettingsState extends State<_PlaybackCacheSettings> {
  PlaybackCacheStatus? _status;
  bool _busy = true;
  bool _failed = false;
  static const _mib = 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _run(PlaybackCache.status);
  }

  Future<void> _run(Future<PlaybackCacheStatus> Function() action) async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final status = await action();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _configure({bool? enabled, int? limit}) async {
    final status = _status;
    if (status == null || _busy) return;
    widget.beforeChange();
    await _run(() async {
      final configured = await PlaybackCache.configure(
          enabled: enabled ?? status.enabled,
          maxBytes: limit ?? status.maxBytes);
      if (configured.maxBytes < status.maxBytes) {
        await widget.downloads?.reconcileOfflineDiscoveryBudget();
      }
      return configured;
    });
  }

  Future<void> _clear() async {
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => AlertDialog(
        title: Text(locals.playbackCacheClear),
        content: Text(locals.playbackCacheClearHint),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.playbackCacheClear)),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    widget.beforeChange();
    await _run(PlaybackCache.clear);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final status = _status;
    final sizes = <int>{
      128,
      256,
      512,
      1024,
      2048,
      if (status != null) status.maxBytes ~/ _mib
    }.toList()
      ..sort();
    return AlertDialog(
      title: Text(locals.playbackCache),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.playbackCacheHint),
            if (_busy) const LinearProgressIndicator(),
            if (_failed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(locals.playbackCacheError),
              ),
            if (status != null && !status.supported)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(locals.playbackCacheUnavailable),
              ),
            if (status?.supported == true) ...[
              Text(locals.playbackCacheDiscoveryHint),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(locals.playbackCache),
                value: status!.enabled,
                onChanged: _busy ? null : (value) => _configure(enabled: value),
              ),
              Text(locals.playbackCacheUsed(
                  '${(status.usedBytes / _mib).toStringAsFixed(1)} MiB',
                  '${status.maxBytes ~/ _mib} MiB')),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: status.maxBytes ~/ _mib,
                decoration:
                    InputDecoration(labelText: locals.playbackCacheSize),
                items: [
                  for (final size in sizes)
                    DropdownMenuItem(value: size, child: Text('$size MiB')),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) _configure(limit: value * _mib);
                      },
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _busy ? null : _clear,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(locals.playbackCacheClear),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel)),
      ],
    );
  }
}
