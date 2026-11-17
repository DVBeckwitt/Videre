import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> showMusicDetailsDialog(
    BuildContext context, List<MusicLibraryEntry> entries) async {
  final session = MusicLibrarySession(context.read<AppCubit>());
  if (!session.isCurrent || NetworkProxy.instance.isChanging) return;
  final ids = [
    for (final entry in entries)
      if (entry.needsSongDetails) entry.id,
  ];
  if (ids.isEmpty) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => _MusicDetailsDialog(session: session, ids: ids),
  );
}

class _MusicDetailsDialog extends StatefulWidget {
  const _MusicDetailsDialog({required this.session, required this.ids});

  final MusicLibrarySession session;
  final List<String> ids;

  @override
  State<_MusicDetailsDialog> createState() => _MusicDetailsDialogState();
}

class _MusicDetailsDialogState extends State<_MusicDetailsDialog> {
  static const _batchSize = 8;
  final _database = db;
  final _proxy = NetworkProxy.instance.config;
  late final StreamSubscription<AppState> _sessionChanges;
  int _checked = 0;
  int _updated = 0;
  bool _running = false;
  bool _finished = false;
  bool _interrupted = false;
  bool _connectionChanged = false;
  bool _cancelled = false;

  bool get _isCurrent =>
      mounted &&
      !_cancelled &&
      !_connectionChanged &&
      identical(db, _database) &&
      widget.session.isCurrent &&
      !NetworkProxy.instance.isChanging &&
      identical(NetworkProxy.instance.config, _proxy);

  @override
  void initState() {
    super.initState();
    _sessionChanges = widget.session.app.stream.listen((_) {
      if (!_isCurrent) _stopForConnection();
    });
    NetworkProxy.instance.addBeforeApply(_stopForConnection);
  }

  Future<void> _stopForConnection() async {
    if (!mounted || _cancelled || _finished) return;
    setState(() {
      _connectionChanged = true;
      _running = false;
      _finished = true;
    });
  }

  @override
  void dispose() {
    _cancelled = true;
    unawaited(_sessionChanges.cancel());
    NetworkProxy.instance.removeBeforeApply(_stopForConnection);
    super.dispose();
  }

  Future<void> _load() async {
    if (_running || _finished) return;
    if (!_isCurrent) {
      await _stopForConnection();
      return;
    }
    setState(() => _running = true);
    final pending = <MusicLibraryEntry>[];
    Future<void> flush() async {
      if (!_isCurrent || pending.isEmpty) return;
      final batch = List<MusicLibraryEntry>.of(pending);
      pending.clear();
      final count = await widget.session.library
          .fillSongDetails(batch, isCurrent: () => _isCurrent);
      if (_isCurrent) setState(() => _updated += count);
    }

    var stopped = false;
    try {
      await musicCatalogService.loadSavedSongDetails(
        widget.ids,
        isCurrent: () => _isCurrent,
        onResult: (_, details) async {
          if (!_isCurrent) return;
          setState(() => _checked++);
          if (details == null) return;
          pending.add(details);
          if (pending.length >= _batchSize) await flush();
        },
      );
    } catch (_) {
      stopped = true;
    }
    if (!_isCurrent) {
      await _stopForConnection();
      return;
    }
    try {
      await flush();
    } catch (_) {
      stopped = true;
    }
    if (!_isCurrent) {
      await _stopForConnection();
      return;
    }
    setState(() {
      _running = false;
      _finished = true;
      _interrupted = stopped;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final total = widget.ids.length;
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancelled = true;
      },
      child: AlertDialog(
        title: Text(locals.musicLoadSongDetails),
        scrollable: true,
        content: SizedBox(
          width: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_running) ...[
                LinearProgressIndicator(value: _checked / total),
                const SizedBox(height: 12),
                Text(locals.musicDetailsProgress(_checked, total)),
              ] else if (!_finished)
                Text(locals.musicDetailsExplanation)
              else ...[
                if (_updated > 0)
                  Text(locals.musicDetailsResult(_updated, total)),
                if (_connectionChanged)
                  Text(locals.musicDetailsConnectionChanged)
                else if (_interrupted)
                  Text(locals.musicDetailsInterrupted)
                else if (_updated == 0)
                  Text(locals.musicDetailsUnavailable),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              _cancelled = true;
              Navigator.of(context).pop();
            },
            child: Text(_finished
                ? MaterialLocalizations.of(context).closeButtonLabel
                : locals.cancel),
          ),
          if (!_running && !_finished)
            FilledButton(
              onPressed: _load,
              child: Text(locals.musicDetailsLoad),
            ),
        ],
      ),
    );
  }
}
