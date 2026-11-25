import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/pretty_bytes.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as path;

import 'music_duration_label.dart';

/// Inspects the selected song or file without fetching catalog metadata.
Future<void> showMusicTrackDetails(
  BuildContext context, {
  Video? song,
  LocalMusicTrack? device,
  DownloadedVideo? download,
  String? downloadFileProof,
  bool inPlayer = false,
}) async {
  assert([song, device, download].nonNulls.length == 1);
  final app = context.read<AppCubit>();
  final database = db;
  final profileId = database.profileId;
  final session = app.state;
  bool current() {
    final active = app.state;
    return !app.isClosed &&
        !active.globalLoading &&
        !active.sessionRecoveryRequired &&
        identical(db, database) &&
        db.profileId == profileId &&
        session.profileId == profileId &&
        active.profileId == session.profileId &&
        active.sessionRevision == session.sessionRevision &&
        active.server == session.server;
  }

  if (!current() ||
      (download != null &&
          (download.profileId != profileId ||
              !download.downloadComplete ||
              download.downloadFailed ||
              download.storageFailed ||
              download.authenticationRequired))) {
    return;
  }
  final music = download?.musicMetadata ?? song?.musicMetadata;
  final title = _known(device?.title ?? music?.title) ??
      _known(download?.title ?? song?.title);
  final downloadFile = download == null
      ? null
      : _probeDownload(download, profileId, downloadFileProof);
  final navigator = Navigator.of(context);
  final route = DialogRoute<void>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    animationStyle: AppMotion.dialogStyle(context),
    settings: const RouteSettings(name: 'music-track-details'),
    builder: (context) {
      final locals = AppLocalizations.of(context)!;
      final material = MaterialLocalizations.of(context);
      final file = device != null || download != null;
      final duration = device != null
          ? Duration(milliseconds: device.durationMs)
          : Duration(
              seconds: download?.lengthSeconds ?? song?.lengthSeconds ?? 0);
      final deviceName = _fileName(device?.fileName);
      final extension = deviceName == null ? '' : path.extension(deviceName);
      final downloadFormat = download == null
          ? null
          : download.musicFormat?.label ??
              download.container?.extension(download.audioOnly).toUpperCase();
      final dialog = _TrackDetailsDialog(
        title: file ? locals.musicTrackFileDetails : locals.musicTrackDetails,
        songTitle: title ?? locals.musicTrackDetailsUnknown,
        fields: [
          (
            locals.musicTrackDetailsSource,
            device != null
                ? locals.musicTrackDetailsDevice
                : download != null
                    ? locals.musicTrackDetailsDownload
                    : locals.musicTrackDetailsCatalog,
          ),
          (locals.localMusicSortArtist, device?.artist ?? music?.artist),
          (locals.localMusicSortAlbum, device?.album ?? music?.album),
          (
            locals.searchDuration,
            duration > Duration.zero
                ? formatMusicDuration(duration.inSeconds)
                : null,
          ),
          if (device != null) ...[
            (locals.localMusicFileName, deviceName),
            (
              locals.musicTrackDetailsExtension,
              _fileExtension.hasMatch(extension)
                  ? extension.substring(1).toUpperCase()
                  : null,
            ),
            (locals.musicTrackDetailsSize, _size(device.sizeBytes)),
            if (device.dateAdded case final date?)
              (
                device.firstSeen
                    ? locals.localMusicFirstSeen
                    : locals.localMusicSortDateAdded,
                material.formatMediumDate(date.toLocal()),
              ),
            if (device.dateModified case final date?)
              (
                locals.localMusicSortDateModified,
                material.formatMediumDate(date.toLocal()),
              ),
          ],
          if (download != null)
            (locals.musicTrackDetailsFormat, downloadFormat),
        ],
        downloadFile: downloadFile,
      );
      return inPlayer ? PlayerModalBackHandler(child: dialog) : dialog;
    },
  );
  final changes = app.stream.listen((_) {
    if (route.isActive && !current()) navigator.removeRoute(route);
  });
  try {
    await navigator.push(route);
  } finally {
    await changes.cancel();
  }
}

typedef _DownloadFile = ({String? name, int bytes});

Future<_DownloadFile?> _probeDownload(
    DownloadedVideo download, String profileId, String? expectedProof) async {
  try {
    final probes =
        await DownloadStorage().probeMusicFiles(profileId, [download]).timeout(
      const Duration(seconds: 3),
      onTimeout: () => const [],
    );
    final probe = probes.firstOrNull;
    if (probe == null ||
        (expectedProof != null && probe.identity != expectedProof)) {
      return null;
    }
    final uri = Uri.parse(probe.uri);
    return (
      name:
          uri.scheme == 'file' ? _fileName(uri.pathSegments.lastOrNull) : null,
      bytes: probe.byteLength,
    );
  } on Exception {
    return null;
  }
}

final _fileExtension = RegExp(r'^\.[A-Za-z0-9]{1,12}$');
final _fileNameInvalid = RegExp(r'[/\\\x00-\x1f\x7f]');

String? _fileName(String? value) =>
    value == null || _fileNameInvalid.hasMatch(value) ? null : _known(value);

String? _known(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty || text.toLowerCase() == '<unknown>'
      ? null
      : text;
}

String? _size(int? bytes) =>
    bytes != null && bytes > 0 ? prettyBytes(bytes.toDouble()) : null;

class _TrackDetailsDialog extends StatefulWidget {
  final String title;
  final String songTitle;
  final List<(String, String?)> fields;
  final Future<_DownloadFile?>? downloadFile;

  const _TrackDetailsDialog({
    required this.title,
    required this.songTitle,
    required this.fields,
    required this.downloadFile,
  });

  @override
  State<_TrackDetailsDialog> createState() => _TrackDetailsDialogState();
}

class _TrackDetailsDialogState extends State<_TrackDetailsDialog> {
  final _scroll = ScrollController();

  void _scrollBy(double delta) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _scroll.jumpTo((_scroll.offset + delta)
        .clamp(position.minScrollExtent, position.maxScrollExtent));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    Widget field(String label, String? value) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: textTheme.labelLarge),
                Text(_known(value) ?? locals.musicTrackDetailsUnknown),
              ],
            ),
          ),
        );
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              _scrollBy(-56),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _scrollBy(56),
        },
        child: AlertDialog(
          title: Text(widget.title),
          content: SingleChildScrollView(
            controller: _scroll,
            child: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(widget.songTitle, style: textTheme.titleMedium),
                  ),
                  for (final (label, value) in widget.fields)
                    field(label, value),
                  if (widget.downloadFile != null)
                    FutureBuilder<_DownloadFile?>(
                      future: widget.downloadFile,
                      builder: (context, snapshot) =>
                          snapshot.connectionState != ConnectionState.done
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(
                                        locals.musicTrackDetailsCheckingFile),
                                  ),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    field(locals.localMusicFileName,
                                        snapshot.data?.name),
                                    field(locals.musicTrackDetailsSize,
                                        _size(snapshot.data?.bytes)),
                                  ],
                                ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      ),
    );
  }
}
