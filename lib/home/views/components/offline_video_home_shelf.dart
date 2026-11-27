import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/download_storage.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/states/player.dart';
import '../../../player/views/tv/screens/tv_player_view.dart';
import '../../../utils/interfaces/db.dart';
import '../../services/offline_video_downloads.dart';

class OfflineVideoHomeShelf extends StatefulWidget {
  const OfflineVideoHomeShelf({
    super.key,
    required this.owner,
    required this.isCurrent,
    required this.include,
    required this.admissionChanges,
    required this.online,
    required this.television,
  });

  final IDbClient owner;
  final bool Function() isCurrent;
  final bool Function(DownloadedVideo) include;
  final Listenable admissionChanges;
  final bool online;
  final bool television;

  @override
  State<OfflineVideoHomeShelf> createState() => _OfflineVideoHomeShelfState();
}

class _OfflineVideoHomeShelfState extends State<OfflineVideoHomeShelf>
    with WidgetsBindingObserver {
  late final _manager = context.read<DownloadManagerCubit?>();
  late final _storage = _manager?.storage ?? DownloadStorage();
  StreamSubscription<DownloadManagerState>? _downloadChanges;
  List<DownloadedVideo>? _lastRecords;
  List<DownloadedVideo>? _downloads;
  Object? _read;
  bool _opening = false;

  bool get _current => mounted && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.admissionChanges.addListener(_reload);
    _lastRecords = _manager?.state.videos;
    _downloadChanges = _manager?.stream.listen((state) {
      if (identical(state.videos, _lastRecords) ||
          listEquals(state.videos, _lastRecords)) {
        return;
      }
      _lastRecords = state.videos;
      _reload();
    });
    _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.admissionChanges.removeListener(_reload);
    unawaited(_downloadChanges?.cancel());
    super.dispose();
  }

  Future<List<DownloadedVideo>> _readDownloads(
          {DownloadedVideo? selection, required bool Function() isCurrent}) =>
      readableHomeDownloads(
        owner: widget.owner,
        storage: _storage,
        isCurrent: isCurrent,
        include: widget.include,
        limit: 6,
        selection: selection,
      );

  void _reload() {
    if (!_current) return;
    final token = _read = Object();
    bool valid() => _current && identical(token, _read);
    unawaited(_readDownloads(isCurrent: valid).then((downloads) {
      if (valid()) setState(() => _downloads = downloads);
    }));
  }

  Future<void> _open(DownloadedVideo download) async {
    if (!_current || _opening) return;
    _opening = true;
    try {
      final ready =
          await _readDownloads(selection: download, isCurrent: () => _current);
      if (!mounted ||
          !widget.isCurrent() ||
          ModalRoute.isCurrentOf(context) == false) {
        return;
      }
      if (ready.isEmpty) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(locals.flowHomeDownloadUnavailable)));
        _reload();
        return;
      }
      final selected = ready.single;
      if (widget.television) {
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              TvPlayerScreen.download(download: selected, fromMusic: false),
        ));
      } else {
        await context.read<PlayerCubit>().playOfflineVideos([selected]);
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final downloads = _downloads?.where(widget.include).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              widget.online
                  ? locals.flowHomeBackOnline
                  : locals.flowHomeOffline,
              style: theme.textTheme.titleMedium),
          if (downloads == null)
            const LinearProgressIndicator(minHeight: 2)
          else if (downloads.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(locals.flowHomeOfflineEmpty),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Text(locals.downloads, style: theme.textTheme.titleSmall),
            ),
            for (final download in downloads)
              ListTile(
                key: ValueKey('flow-offline-video-${download.videoId}'),
                leading: const Icon(Icons.video_file_outlined),
                title: Text(download.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: download.author?.trim().isNotEmpty == true
                    ? Text(download.author!,
                        maxLines: 1, overflow: TextOverflow.ellipsis)
                    : null,
                trailing: const Icon(Icons.play_arrow),
                onTap: () => unawaited(_open(download)),
              ),
          ],
        ],
      ),
    );
  }
}
