import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/music_download_storage.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/pretty_bytes.dart';

/// Reports the entire managed collection, independently of its display order.
class MusicDownloadStorageSummary extends StatefulWidget {
  final String profileId;
  final Set<DownloadedVideo> downloads;
  final bool transferring;

  const MusicDownloadStorageSummary(
      {super.key,
      required this.profileId,
      required this.downloads,
      required this.transferring});

  @override
  State<MusicDownloadStorageSummary> createState() =>
      _MusicDownloadStorageSummaryState();
}

class _MusicDownloadStorageSummaryState
    extends State<MusicDownloadStorageSummary> with WidgetsBindingObserver {
  static const _refreshInterval = Duration(seconds: 2);

  Object _collection = Object();
  Future<MusicDownloadStorageUsage>? _measurement;
  bool _measuring = false;
  bool _visible = false;
  bool _foreground = true;
  Timer? _refresh;

  bool get _active => _visible && _foreground;

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.of(context);
    if (_visible == visible) return;
    _visible = visible;
    if (_active) _measure();
    _updateRefresh();
  }

  @override
  void didUpdateWidget(MusicDownloadStorageSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed = widget.profileId != oldWidget.profileId ||
        !setEquals(widget.downloads, oldWidget.downloads);
    final transferChanged = widget.transferring != oldWidget.transferring;
    if (changed) {
      // A measurement of a removed file or previous profile must not be shown
      // when the files being measured change.
      _collection = Object();
      _measurement = null;
    }
    if (_active && (changed || transferChanged)) _measure();
    if (transferChanged) _updateRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (_active) setState(_measure);
    _updateRefresh();
  }

  void _measure() {
    final future = measureMusicDownloadStorage(widget.downloads,
        profileId: widget.profileId);
    _measurement = future;
    _measuring = true;
    void finished() {
      if (identical(future, _measurement)) _measuring = false;
    }

    unawaited(future.then<void>((_) => finished(),
        onError: (Object _, StackTrace __) => finished()));
  }

  void _updateRefresh() {
    _refresh?.cancel();
    _refresh = _active && widget.transferring
        ? Timer.periodic(_refreshInterval, (_) {
            if (!_measuring) setState(_measure);
          })
        : null;
  }

  @override
  void dispose() {
    _refresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return FutureBuilder(
      key: ObjectKey(_collection),
      future: _measurement,
      builder: (context, snapshot) {
        final usage = snapshot.data;
        final String label;
        if (snapshot.hasError ||
            (usage != null && usage.incomplete && usage.bytes == 0)) {
          label = locals.musicDownloadsStorageUnknown;
        } else if (usage == null) {
          label = locals.musicDownloadsStorageLoading;
        } else {
          final size = prettyBytes(usage.bytes.toDouble());
          label = usage.incomplete
              ? locals.musicDownloadsStoragePartial(size)
              : locals.musicDownloadsStorageUsage(size);
        }
        return Text(label,
            key: const ValueKey('music-downloads-storage'),
            style: Theme.of(context).textTheme.bodySmall);
      },
    );
  }
}
