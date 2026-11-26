import 'package:clipious/app/states/app.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/services/download_storage.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/music_file_audio_format.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/music/models/music_recording_rating.dart';
import 'package:clipious/music/services/music_recording_rating_store.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/pretty_bytes.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

import 'music_duration_label.dart';

/// Inspects the selected song or file without fetching catalog metadata.
Future<void> showMusicTrackDetails(
  BuildContext context, {
  Video? song,
  LocalMusicTrack? device,
  LocalMusicLibrary? library,
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
  final deviceAudio = device == null
      ? null
      : (library ?? LocalMusicLibrary.instance)
          .readTrackAudioFormat(device)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
  final recordingId = device?.playbackId ?? download?.videoId ?? song?.videoId;
  final rating = recordingId != null && isMusicRecordingRatingId(recordingId)
      ? _TrackRating(
          store: MusicRecordingRatingStore.forProfile(database, profileId),
          recordingId: recordingId,
          isCurrent: current,
          inPlayer: inPlayer,
        )
      : null;
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
            ..._deviceTagFields(locals, device),
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
        deviceAudio: deviceAudio,
        downloadFile: downloadFile,
        rating: rating,
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

typedef _DownloadFile = ({
  String? name,
  int bytes,
  MusicFileAudioFormat? audioFormat,
});
typedef _DetailField = (String, String?);

List<_DetailField> _deviceTagFields(
  AppLocalizations locals,
  LocalMusicTrack track,
) {
  final numbers = NumberFormat.decimalPattern(locals.localeName);
  final peaks = NumberFormat.decimalPattern(locals.localeName)
    ..maximumFractionDigits = 8;
  final replayGain = track.replayGain;
  return [
    if (track.trackNumber case final number? when number > 0)
      (locals.musicTrackDetailsTrackNumber, numbers.format(number)),
    if (track.discNumber case final number? when number > 0)
      (locals.musicTrackDetailsDiscNumber, numbers.format(number)),
    if (_known(track.genre) case final genre?)
      (locals.musicTrackDetailsGenre, genre),
    if (replayGain?.trackGainDb case final gain? when gain.isFinite)
      (
        locals.musicTrackDetailsTrackGain,
        locals.musicTrackDetailsGainValue(numbers.format(gain)),
      ),
    if (replayGain?.albumGainDb case final gain? when gain.isFinite)
      (
        locals.musicTrackDetailsAlbumGain,
        locals.musicTrackDetailsGainValue(numbers.format(gain)),
      ),
    if (replayGain?.trackPeak case final peak? when peak.isFinite && peak > 0)
      (locals.musicTrackDetailsTrackPeak, peaks.format(peak)),
    if (replayGain?.albumPeak case final peak? when peak.isFinite && peak > 0)
      (locals.musicTrackDetailsAlbumPeak, peaks.format(peak)),
  ];
}

List<_DetailField> _audioFormatFields(
  AppLocalizations locals,
  MusicFileAudioFormat? audioFormat,
) {
  if (audioFormat == null) return const [];
  final numbers = NumberFormat.decimalPattern(locals.localeName);
  return [
    if (audioFormat.codec case final codec?)
      (locals.musicTrackDetailsCodec, codec),
    if (audioFormat.bitrateBps case final bitrate?)
      (
        locals.musicTrackDetailsBitrate,
        locals.musicTrackDetailsBitrateValue(numbers.format(bitrate / 1000)),
      ),
    if (audioFormat.sampleRateHz case final sampleRate?)
      (
        locals.musicTrackDetailsSampleRate,
        locals.musicTrackDetailsSampleRateValue(
          numbers.format(sampleRate / 1000),
        ),
      ),
  ];
}

Future<_DownloadFile?> _probeDownload(
  DownloadedVideo download,
  String profileId,
  String? expectedProof,
) async {
  try {
    if (download.profileId != profileId) return null;
    final probe = await DownloadStorage()
        .inspectMusicFile(download, expectedIdentity: expectedProof)
        .timeout(const Duration(seconds: 3), onTimeout: () => null);
    if (probe == null) return null;
    final uri = Uri.parse(probe.uri);
    return (
      name:
          uri.scheme == 'file' ? _fileName(uri.pathSegments.lastOrNull) : null,
      bytes: probe.byteLength,
      audioFormat: probe.audioFormat,
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
  final List<_DetailField> fields;
  final Future<MusicFileAudioFormat?>? deviceAudio;
  final Future<_DownloadFile?>? downloadFile;
  final Widget? rating;

  const _TrackDetailsDialog({
    required this.title,
    required this.songTitle,
    required this.fields,
    required this.deviceAudio,
    required this.downloadFile,
    required this.rating,
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

  void _moveFocusOrScroll(TraversalDirection direction, double delta) {
    // Move between dialog actions if they wrap onto separate rows.
    if (FocusManager.instance.primaryFocus?.focusInDirection(direction) !=
        true) {
      _scrollBy(delta);
    }
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
    Widget checkingFile() => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Semantics(
            liveRegion: true,
            child: Text(locals.musicTrackDetailsCheckingFile),
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
              _moveFocusOrScroll(TraversalDirection.up, -56),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              _moveFocusOrScroll(TraversalDirection.down, 56),
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
                  if (widget.deviceAudio != null)
                    FutureBuilder<MusicFileAudioFormat?>(
                      future: widget.deviceAudio,
                      builder: (context, snapshot) =>
                          snapshot.connectionState != ConnectionState.done
                              ? checkingFile()
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final (label, value)
                                        in _audioFormatFields(
                                      locals,
                                      snapshot.data,
                                    ))
                                      field(label, value),
                                  ],
                                ),
                    ),
                  if (widget.downloadFile != null)
                    FutureBuilder<_DownloadFile?>(
                      future: widget.downloadFile,
                      builder: (context, snapshot) =>
                          snapshot.connectionState != ConnectionState.done
                              ? checkingFile()
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    field(
                                      locals.localMusicFileName,
                                      snapshot.data?.name,
                                    ),
                                    field(
                                      locals.musicTrackDetailsSize,
                                      _size(snapshot.data?.bytes),
                                    ),
                                    for (final (label, value)
                                        in _audioFormatFields(
                                      locals,
                                      snapshot.data?.audioFormat,
                                    ))
                                      field(label, value),
                                  ],
                                ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            if (widget.rating case final rating?) rating,
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

class _TrackRating extends StatefulWidget {
  final MusicRecordingRatingStore store;
  final String recordingId;
  final bool Function() isCurrent;
  final bool inPlayer;

  const _TrackRating({
    required this.store,
    required this.recordingId,
    required this.isCurrent,
    required this.inPlayer,
  });

  @override
  State<_TrackRating> createState() => _TrackRatingState();
}

class _TrackRatingState extends State<_TrackRating> {
  int _request = 0;
  bool _saveFailed = false;

  Future<void> _setRating(int? rating) async {
    if (!mounted) return;
    final current = widget.isCurrent;
    if (!current()) return;
    final request = ++_request;
    if (_saveFailed) setState(() => _saveFailed = false);
    try {
      await widget.store
          .setRating(widget.recordingId, rating, isCurrent: current);
    } catch (_) {
      if (mounted && request == _request && current()) {
        setState(() => _saveFailed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final detailsRoute = widget.inPlayer ? ModalRoute.of(context) : null;
    Widget option(String text) {
      final label = Text(text);
      if (detailsRoute == null) return label;
      // DropdownButton builds its labels in both the details and popup routes.
      // The visible popup rows intercept Back before the expanded player.
      return Builder(
          builder: (itemContext) => ModalRoute.of(itemContext) == detailsRoute
              ? label
              : PlayerModalBackHandler(priority: 6, child: label));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MergeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(locals.musicRecordingRating,
                  style: Theme.of(context).textTheme.labelMedium),
              ListenableBuilder(
                listenable: widget.store.changes,
                builder: (context, _) => DropdownButton<int>(
                  key: const ValueKey('music-recording-rating'),
                  value: widget.store.ratings[widget.recordingId],
                  items: [
                    DropdownMenuItem(
                        child: option(locals.musicRecordingRatingUnset)),
                    for (var stars = musicMinimumRecordingRating;
                        stars <= musicMaximumRecordingRating;
                        stars++)
                      DropdownMenuItem(
                        value: stars,
                        child: option(locals.musicRecordingRatingStars(stars)),
                      ),
                  ],
                  onChanged: _setRating,
                ),
              ),
            ],
          ),
        ),
        if (_saveFailed)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Semantics(
              liveRegion: true,
              child: Text(locals.musicLibraryActionError,
                  style: TextStyle(color: ColorScheme.of(context).error)),
            ),
          ),
      ],
    );
  }
}
