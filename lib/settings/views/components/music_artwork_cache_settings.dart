import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../music/models/music_artwork_cache.dart';
import '../../../music/services/device_music_artwork_cache.dart';
import '../../../music/services/music_artwork_cache.dart';
import '../../../player/notification_artwork_cache.dart';
import '../../../utils.dart' show selectKeys;
import '../../../utils/interfaces/db.dart';
import '../../../utils/motion.dart';
import '../../../utils/pretty_bytes.dart';

Widget _selectable(Widget child) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: child,
    );

class MusicArtworkCacheSettings extends StatelessWidget {
  final MusicArtworkCache? cache;
  final FocusNode? focusNode;

  const MusicArtworkCacheSettings({super.key, this.cache, this.focusNode});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>();
    final database = db;
    final profile = app.state.profileId;
    final session = app.state.sessionRevision;
    bool isCurrent() =>
        context.mounted &&
        !app.isClosed &&
        identical(db, database) &&
        database.profileId == profile &&
        app.state.profileId == profile &&
        app.state.sessionRevision == session &&
        !app.state.globalLoading &&
        !app.state.sessionRecoveryRequired;

    final locals = AppLocalizations.of(context)!;
    return _selectable(ListTile(
      key: const ValueKey('music-artwork-cache-setting'),
      focusNode: focusNode,
      leading: const Icon(Icons.image_outlined),
      title: Text(locals.musicArtworkCache),
      subtitle: Text(locals.musicArtworkCacheHint),
      enabled: isCurrent(),
      onTap: () {
        if (!isCurrent()) return;
        final owner = database.forProfile(profile);
        showDialog<void>(
          context: context,
          useRootNavigator: false,
          animationStyle: AppMotion.dialogStyle(context),
          builder: (_) => _selectable(_ArtworkCacheDialog(
            app: app,
            cache: cache ?? musicArtworkCache,
            owner: owner,
            isCurrent: isCurrent,
          )),
        );
      },
    ));
  }
}

class MusicDeviceArtworkSettings extends StatelessWidget {
  const MusicDeviceArtworkSettings({
    super.key,
    this.deviceCache,
    this.notificationCache,
  });

  final DeviceMusicArtworkCache? deviceCache;
  final NotificationArtworkCache? notificationCache;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }

    final locals = AppLocalizations.of(context)!;
    final device = deviceCache ?? deviceMusicArtworkCache;
    final notification = notificationCache ?? notificationArtworkCache;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DeviceArtworkTile(
          key: const ValueKey('music-device-artwork-cache-setting'),
          icon: Icons.perm_media_outlined,
          title: locals.musicDeviceArtworkCache,
          details: locals.musicDeviceArtworkCacheHint,
          limitLabel: locals.musicDeviceArtworkCacheLimit,
          clearHint: locals.musicDeviceArtworkCacheClearHint,
          read: device.read,
          clear: device.clear,
        ),
        _DeviceArtworkTile(
          key: const ValueKey('music-notification-artwork-cache-setting'),
          icon: Icons.notifications_outlined,
          title: locals.musicNotificationArtworkCache,
          details: locals.musicNotificationArtworkCacheHint,
          limitLabel: locals.musicNotificationArtworkCacheLimit,
          clearHint: locals.musicNotificationArtworkCacheClearHint,
          read: notification.read,
          clear: notification.clear,
        ),
      ],
    );
  }
}

typedef _DeviceArtworkStatus = ({int usedBytes, int limitBytes, bool canClear});

class _DeviceArtworkTile extends StatelessWidget {
  const _DeviceArtworkTile({
    super.key,
    required this.icon,
    required this.title,
    required this.details,
    required this.limitLabel,
    required this.clearHint,
    required this.read,
    required this.clear,
  });

  final IconData icon;
  final String title;
  final String details;
  final String Function(String) limitLabel;
  final String clearHint;
  final Future<_DeviceArtworkStatus> Function() read;
  final Future<_DeviceArtworkStatus> Function() clear;

  @override
  Widget build(BuildContext context) => _selectable(
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(details),
          onTap: () => showDialog<void>(
            context: context,
            useRootNavigator: false,
            animationStyle: AppMotion.dialogStyle(context),
            builder: (_) => _selectable(_DeviceArtworkDialog(store: this)),
          ),
        ),
      );
}

class _DeviceArtworkDialog extends StatefulWidget {
  const _DeviceArtworkDialog({required this.store});

  final _DeviceArtworkTile store;

  @override
  State<_DeviceArtworkDialog> createState() => _DeviceArtworkDialogState();
}

class _DeviceArtworkDialogState extends State<_DeviceArtworkDialog> {
  late Future<_DeviceArtworkStatus> _result = Future.sync(widget.store.read);

  Future<void> _clear() async {
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => _selectable(
        AlertDialog(
          title: Text(locals.musicDeviceArtworkClear),
          content: Text(widget.store.clearHint),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel),
            ),
            FilledButton(
              key: const ValueKey('music-device-artwork-cache-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.musicDeviceArtworkClear),
            ),
          ],
        ),
      ),
    );
    if (mounted && confirmed == true) _load(widget.store.clear);
  }

  void _load(Future<_DeviceArtworkStatus> Function() action) {
    final result = Future.sync(action);
    setState(() {
      _result = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return FutureBuilder<_DeviceArtworkStatus>(
      future: _result,
      builder: (context, snapshot) {
        final busy = snapshot.connectionState == ConnectionState.waiting;
        final status = snapshot.data;
        return AlertDialog(
          title: Text(widget.store.title),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Text(widget.store.details),
              if (busy) const LinearProgressIndicator(),
              if (snapshot.hasError && !busy)
                Text(locals.musicArtworkCacheError),
              if (status != null) ...[
                Text(
                  locals.musicArtworkCacheUsed(
                    prettyBytes(status.usedBytes.toDouble(), binary: true),
                  ),
                ),
                Text(
                  widget.store.limitLabel(
                    prettyBytes(status.limitBytes.toDouble(), binary: true),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('music-device-artwork-cache-clear'),
                  onPressed: !busy && status.canClear ? _clear : null,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(locals.musicDeviceArtworkClear),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => _load(widget.store.read),
              child: Text(locals.refresh),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        );
      },
    );
  }
}

class _ArtworkCacheDialog extends StatefulWidget {
  final AppCubit app;
  final MusicArtworkCache cache;
  final IDbClient owner;
  final bool Function() isCurrent;
  const _ArtworkCacheDialog({
    required this.app,
    required this.cache,
    required this.owner,
    required this.isCurrent,
  });

  @override
  State<_ArtworkCacheDialog> createState() => _ArtworkCacheDialogState();
}

class _ArtworkCacheDialogState extends State<_ArtworkCacheDialog> {
  MusicArtworkCacheStatus? _status;
  bool _busy = false;
  bool _failed = false;

  bool get _current => mounted && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _run(Future<MusicArtworkCacheStatus> Function() work) async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final status = await work();
      if (_current) setState(() => _status = status);
    } catch (_) {
      if (_current) {
        setState(() {
          _status = null;
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() => _run(() => widget.cache.read(widget.owner));

  Future<void> _configure(int? limit) async {
    if (limit == null || limit == _status?.limitMiB) return;
    await _run(() =>
        widget.cache.configure(widget.owner, limit, isCurrent: () => _current));
  }

  Future<void> _clear() async {
    if (!_current || _busy) return;
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => BlocBuilder<AppCubit, AppState>(
        bloc: widget.app,
        builder: (context, _) => _selectable(AlertDialog(
          title: Text(locals.musicArtworkCacheClear),
          content: Text(locals.musicArtworkCacheClearHint),
          actions: [
            TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: Text(locals.cancel)),
            FilledButton(
                key: const ValueKey('music-artwork-cache-confirm'),
                onPressed: _current ? () => Navigator.pop(context, true) : null,
                child: Text(locals.musicArtworkCacheClear)),
          ],
        )),
      ),
    );
    if (confirmed == true && _current) {
      await _run(
          () => widget.cache.clear(widget.owner, isCurrent: () => _current));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return BlocBuilder<AppCubit, AppState>(
      bloc: widget.app,
      builder: (context, _) {
        final current = _current;
        final status = current ? _status : null;
        return AlertDialog(
          title: Text(locals.musicArtworkCache),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(locals.musicArtworkCacheHint),
                if (_busy && current) const LinearProgressIndicator(),
                if (_failed || !current)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(locals.musicArtworkCacheError),
                  ),
                if (status != null) ...[
                  const SizedBox(height: 12),
                  Text(locals.musicArtworkCacheUsed(
                      prettyBytes(status.usedBytes.toDouble(), binary: true))),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    key: ValueKey(
                        ('music-artwork-cache-limit', status.limitMiB)),
                    initialValue: status.limitMiB,
                    decoration: InputDecoration(
                        labelText: locals.musicArtworkCacheLimit),
                    items: [
                      for (final size in musicArtworkCacheLimitsMiB)
                        DropdownMenuItem(value: size, child: Text('$size MiB')),
                    ],
                    onChanged: _busy ? null : _configure,
                  ),
                  TextButton.icon(
                    key: const ValueKey('music-artwork-cache-clear'),
                    onPressed:
                        _busy || (status.usedBytes == 0 && !status.hasTransfers)
                            ? null
                            : _clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: Text(locals.musicArtworkCacheClear),
                  ),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: current && !_busy ? _refresh : null,
                child: Text(locals.refresh)),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child:
                    Text(MaterialLocalizations.of(context).closeButtonLabel)),
          ],
        );
      },
    );
  }
}
