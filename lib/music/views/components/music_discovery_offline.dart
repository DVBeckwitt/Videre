import 'package:flutter/foundation.dart' show listEquals, mapEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/download_storage.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../videos/models/video.dart';
import '../../models/on_device_music_entry.dart';
import '../screens/music.dart';

class MusicDiscoveryOffline extends StatelessWidget {
  const MusicDiscoveryOffline({
    super.key,
    required this.manager,
    required this.profileId,
    required this.isCurrent,
    required this.selectedSongs,
  });

  final DownloadManagerCubit manager;
  final String profileId;
  final bool Function() isCurrent;
  final List<Video> Function()? selectedSongs;

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<DownloadManagerCubit, DownloadManagerState>(
        bloc: manager,
        buildWhen: (before, after) =>
            !listEquals(before.videos, after.videos) ||
            before.wifiOnly != after.wifiOnly ||
            before.waitingForWifi != after.waitingForWifi ||
            before.wifiConnected != after.wifiConnected ||
            !setEquals(before.pausedVideoIds, after.pausedVideoIds),
        builder: (context, state) => ListenableBuilder(
          listenable: manager.discoveryOfflineChanges,
          builder: (context, _) {
            final ids = manager.offlineDiscoveryIds(profileId);
            if (ids.isEmpty && selectedSongs == null) {
              return const SizedBox.shrink();
            }
            final rows = state.videos
                .where((file) =>
                    file.profileId == profileId && ids.contains(file.videoId))
                .toList();
            bool needsAttention(DownloadedVideo file) =>
                !file.audioOnly ||
                file.downloadFailed ||
                file.storageFailed ||
                file.authenticationRequired ||
                state.pausedVideoIds.contains(file.videoId);
            return _OfflineSelection(
              manager: manager,
              profileId: profileId,
              isCurrent: isCurrent,
              selectedSongs: selectedSongs,
              ids: ids,
              completed: {
                for (final file in rows)
                  if (file.downloadComplete && !needsAttention(file))
                    file.videoId: musicDownloadFingerprint(file),
              },
              waitingForWifi: rows.any((file) =>
                  !file.downloadComplete &&
                  !needsAttention(file) &&
                  state.waitingForWifiFor(file)),
              needsAttention:
                  ids.length - rows.length + rows.where(needsAttention).length,
            );
          },
        ),
      );
}

class _OfflineSelection extends StatefulWidget {
  const _OfflineSelection({
    required this.manager,
    required this.profileId,
    required this.isCurrent,
    required this.selectedSongs,
    required this.ids,
    required this.completed,
    required this.waitingForWifi,
    required this.needsAttention,
  });

  final DownloadManagerCubit manager;
  final String profileId;
  final bool Function() isCurrent;
  final List<Video> Function()? selectedSongs;
  final List<String> ids;
  final Map<String, String> completed;
  final bool waitingForWifi;
  final int needsAttention;

  @override
  State<_OfflineSelection> createState() => _OfflineSelectionState();
}

class _OfflineSelectionState extends State<_OfflineSelection>
    with WidgetsBindingObserver {
  Future<List<MusicFileProbe>>? _availability;
  bool _busy = false;
  bool _visible = false;
  late bool _foreground;

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
    final wasVisible = _visible;
    _visible = TickerMode.of(context);
    if (_visible && !wasVisible) _refresh();
  }

  @override
  void didUpdateWidget(_OfflineSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.ids, widget.ids) ||
        !mapEquals(oldWidget.completed, widget.completed)) {
      _refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (_visible && _foreground) setState(_refresh);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _refresh() {
    _availability = _visible && _foreground && widget.completed.isNotEmpty
        ? widget.manager.probeOfflineDiscovery(widget.profileId)
        : null;
  }

  bool get _canAct =>
      mounted &&
      _visible &&
      _foreground &&
      widget.isCurrent() &&
      ModalRoute.isCurrentOf(context) != false;

  Future<void> _update({required bool remove}) async {
    if (_busy || !_canAct) return;
    final songs = remove ? const <Video>[] : widget.selectedSongs?.call();
    if (songs == null || (!remove && songs.isEmpty)) return;
    setState(() => _busy = true);
    try {
      if (await widget.manager.setOfflineDiscovery(widget.profileId, songs) ||
          !_canAct) {
        return;
      }
      _showError();
    } catch (_) {
      if (_canAct) _showError();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(AppLocalizations.of(context)!.musicLibraryActionError)));
  }

  Future<void> _play(List<MusicFileProbe> files, int index) async {
    if (!_canAct) return;
    final sessionIsCurrent = widget.isCurrent;
    final ids = widget.ids;
    if (files.any((file) => !ids.contains(file.download.videoId))) return;
    final manager = widget.manager;
    final profileId = widget.profileId;
    bool current() =>
        mounted &&
        sessionIsCurrent() &&
        listEquals(ids, manager.offlineDiscoveryIds(profileId));
    try {
      await MusicScreen.playOnDeviceTracks(
          context,
          [
            for (final file in files)
              OnDeviceMusicEntry.download(file.download, file.identity),
          ],
          startIndex: index,
          queueTitle: AppLocalizations.of(context)!.musicDiscoveryOffline,
          isCurrent: current);
    } catch (_) {
      if (mounted && _canAct && current()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final keeping = widget.ids.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FutureBuilder<List<MusicFileProbe>>(
        future: _availability,
        builder: (context, snapshot) {
          final files = {
            for (final file in snapshot.data ?? const <MusicFileProbe>[])
              if (widget.completed[file.download.videoId] ==
                  musicDownloadFingerprint(file.download))
                file.download.videoId: file,
          };
          final available = [
            for (final id in widget.ids)
              if (files[id] case final file?) file,
          ];
          final checking = snapshot.connectionState == ConnectionState.waiting;
          final needsAttention = widget.needsAttention +
              (checking ? 0 : widget.completed.length - available.length);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (keeping) ...[
                Text(
                    checking
                        ? locals.musicDiscoveryOfflineChecking
                        : locals.musicDiscoveryOfflineAvailable(
                            available.length, widget.ids.length),
                    key: const ValueKey('music-discovery-offline-status')),
                if (widget.waitingForWifi) Text(locals.downloadsWaitingForWifi),
                if (!_busy && needsAttention > 0)
                  Text(locals.musicPlaylistOfflineAttention(needsAttention)),
              ] else
                Text(locals.musicDiscoveryOfflineHint),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (available.isNotEmpty)
                    FilledButton.tonalIcon(
                      key: const ValueKey('music-discovery-play-offline'),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(locals.musicDiscoveryOfflinePlay),
                      onPressed: _busy ? null : () => _play(available, 0),
                    ),
                  if (widget.selectedSongs != null)
                    OutlinedButton.icon(
                      key: const ValueKey('music-discovery-keep-offline'),
                      icon: Icon(keeping ? Icons.sync : Icons.download),
                      label: Text(keeping
                          ? locals.musicDiscoveryOfflineUpdate
                          : locals.musicDiscoveryOfflineKeep),
                      onPressed: _busy ? null : () => _update(remove: false),
                    ),
                  if (keeping)
                    TextButton(
                      key: const ValueKey('music-discovery-stop-offline'),
                      onPressed: _busy ? null : () => _update(remove: true),
                      child: Text(locals.musicPlaylistStopKeepingOffline),
                    ),
                ],
              ),
              for (final (index, file) in available.indexed)
                ListTile(
                  key: ValueKey(
                      'music-discovery-offline-${file.download.videoId}'),
                  leading: const Icon(Icons.offline_pin_outlined),
                  title: Text(file.download.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: _busy ? null : () => _play(available, index),
                ),
            ],
          );
        },
      ),
    );
  }
}
