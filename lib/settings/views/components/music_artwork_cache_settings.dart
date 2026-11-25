import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../music/models/music_artwork_cache.dart';
import '../../../music/services/music_artwork_cache.dart';
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
  const MusicArtworkCacheSettings({super.key, this.cache});

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
