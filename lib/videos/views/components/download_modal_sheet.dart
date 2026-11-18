import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/states/download_manager.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/pretty_bytes.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/states/download_modal_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class PlaylistDownloadOptions {
  final bool audioOnly;
  final String quality;
  final DownloadContainer? container;

  const PlaylistDownloadOptions(
      {this.audioOnly = false, this.quality = '720p', this.container});
}

class DownloadModalSheet extends StatelessWidget {
  final Video video;
  final Function()? onDownload;
  final Function(bool isDownloadStarted)? onDownloadStarted;

  const DownloadModalSheet(
      {super.key,
      required this.video,
      this.onDownloadStarted,
      this.onDownload});

  static void showVideoModalSheet(BuildContext context, Video video,
      {bool inPlayer = false,
      Function(bool isDownloadStarted)? onDownloadStarted,
      Function()? onDownload}) {
    showSafeModalBottomSheet<void>(
        isScrollControlled: true,
        showDragHandle: true,
        context: context,
        builder: (_) {
          final sheet = DownloadModalSheet(
            video: video,
            onDownload: onDownload,
            onDownloadStarted: onDownloadStarted,
          );
          return inPlayer ? PlayerModalBackHandler(child: sheet) : sheet;
        });
  }

  static Future<PlaylistDownloadOptions?> showPlaylistOptions(
      BuildContext context,
      {bool musicAudioOnly = false}) async {
    final source = db;
    final profileId = db.profileId;
    final accounts = source.getServers();
    final options = await showSafeModalBottomSheet<PlaylistDownloadOptions>(
        isScrollControlled: true,
        showDragHandle: true,
        context: context,
        builder: (_) => _PlaylistDownloadSheet(musicAudioOnly: musicAudioOnly));
    if (options == null ||
        !identical(source, db) ||
        profileId != db.profileId) {
      return null;
    }
    final before = await accounts;
    final after = await source.getServers();
    if (profileId != db.profileId || !identical(source, db)) return null;
    final previous = before.where((server) => server.inUse).firstOrNull;
    final current = after.where((server) => server.inUse).firstOrNull;
    return previous?.accountId == current?.accountId ? options : null;
  }

  Future<void> downloadVideo(
      BuildContext context, DownloadModalSheetState state) async {
    final manager = context.read<DownloadManagerCubit>();
    final locals = AppLocalizations.of(context)!;
    if (!await context.read<DownloadModalSheetCubit>().canStartDownload() ||
        !context.mounted) {
      return;
    }
    onDownload?.call();
    Navigator.of(context).pop();
    try {
      final added = await manager.addDownload(video.videoId,
          audioOnly: state.audioOnly,
          quality: state.quality,
          container: state.container,
          audioTrackId: state.audioTrackId,
          captionLabel: state.captionLabel);
      scaffoldKey.currentState?.showSnackBar(SnackBar(
          content: Text(added
              ? locals.videoDownloadStarted
              : locals.videoAlreadyDownloaded)));
      onDownloadStarted?.call(added);
    } catch (_) {
      scaffoldKey.currentState
          ?.showSnackBar(SnackBar(content: Text(locals.itemlistErrorGeneric)));
      onDownloadStarted?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return BlocProvider(
      create: (_) =>
          DownloadModalSheetCubit(const DownloadModalSheetState(), video),
      child: BlocBuilder<DownloadModalSheetCubit, DownloadModalSheetState>(
          builder: (context, state) {
        final cubit = context.read<DownloadModalSheetCubit>();
        if (state.loading) {
          return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                  heightFactor: 1,
                  child: MotionLoadingIndicator(
                      child: CircularProgressIndicator())));
        }
        if (state.failed) {
          return _SheetBody(children: [
            Text(locals.itemlistErrorGeneric),
            FilledButton.icon(
                autofocus: true,
                onPressed: cubit.init,
                icon: const Icon(Icons.refresh),
                label: Text(locals.retry)),
          ]);
        }
        return _SheetBody(children: [
          if (state.audioTrackDiscoveryFailed)
            Text(locals.downloadAudioLanguagesUnavailable),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(locals.videoDownloadAudioOnly),
              value: state.audioOnly,
              onChanged: !cubit.canSelectVideo ? null : cubit.setAudioOnly),
          _ContainerChoice(
              value: state.container,
              audioOnly: state.audioOnly,
              containers: state.availableContainers,
              onChanged: cubit.setContainer),
          if (!state.audioOnly)
            _Choice<String>(
                label: locals.quality,
                value: state.availableQualities
                    .where((f) => f.qualityLabel == state.quality)
                    .firstOrNull
                    ?.qualityLabel,
                onChanged: cubit.setQuality,
                items: state.availableQualities.map((format) {
                  final size = cubit.estimatedDownloadSize(format);
                  return DropdownMenuItem(
                      value: format.qualityLabel,
                      child: Text(size == null
                          ? format.qualityLabel!
                          : '${format.qualityLabel} (~${prettyBytes(size)})'));
                }).toList()),
          if (state.audioTracks.isNotEmpty)
            _Choice<String>(
                label: locals.downloadAudioTrack,
                value: state.audioTrackId ?? '',
                onChanged: (id) => cubit.setAudioTrack(id == '' ? null : id),
                items: [
                  DropdownMenuItem(
                      value: '', child: Text(locals.downloadDefaultAudio)),
                  for (final track in state.audioTracks)
                    DropdownMenuItem(
                        value: track.id, child: Text(track.displayName)),
                ]),
          if (!state.audioOnly && state.captions.isNotEmpty)
            _Choice<String>(
                label: locals.subtitles,
                value: state.captionLabel ?? '',
                onChanged: (label) =>
                    cubit.setCaption(label == '' ? null : label),
                items: [
                  DropdownMenuItem(
                      value: '', child: Text(locals.downloadNoSubtitles)),
                  for (final label
                      in state.captions.map((c) => c.label).toSet())
                    DropdownMenuItem(value: label, child: Text(label)),
                ]),
          if (state.captionLabel != null)
            Text(locals.downloadEmbeddedSubtitles),
          Align(
              alignment: Alignment.centerRight,
              child: IconButton.filledTonal(
                  tooltip: locals.download,
                  onPressed: () => downloadVideo(context, state),
                  icon: const Icon(Icons.download))),
        ]);
      }),
    );
  }
}

class _SheetBody extends StatelessWidget {
  final List<Widget> children;

  const _SheetBody({required this.children});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children),
        ),
      );
}

class _Choice<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const _Choice(
      {required this.label,
      required this.value,
      required this.items,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              DropdownButton<T>(
                  isExpanded: true,
                  value: value,
                  items: items,
                  onChanged: onChanged),
            ]),
      );
}

class _ContainerChoice extends StatelessWidget {
  final DownloadContainer? value;
  final bool audioOnly;
  final bool musicAudioOnly;
  final List<DownloadContainer> containers;
  final ValueChanged<DownloadContainer?> onChanged;

  const _ContainerChoice(
      {required this.value,
      required this.audioOnly,
      this.musicAudioOnly = false,
      required this.containers,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return _Choice<int>(
        label: musicAudioOnly
            ? locals.musicAudioQuality
            : locals.downloadFileFormat,
        value: value?.index ?? -1,
        onChanged: (index) => onChanged(index == null || index < 0
            ? null
            : DownloadContainer.values[index]),
        items: [
          DropdownMenuItem(
              value: -1,
              child: Text(musicAudioOnly
                  ? locals.musicDownloadHighestQuality
                  : locals.downloadAutomatic)),
          for (final container in containers)
            DropdownMenuItem(
                value: container.index,
                child: Text(container == DownloadContainer.mp4
                    ? audioOnly
                        ? 'M4A (AAC)'
                        : 'MP4 (H.264 / AAC)'
                    : audioOnly
                        ? locals.downloadWebmAudio
                        : 'WebM (VP9 / Opus)')),
        ]);
  }
}

class _PlaylistDownloadSheet extends StatefulWidget {
  final bool musicAudioOnly;

  const _PlaylistDownloadSheet({required this.musicAudioOnly});

  @override
  State<_PlaylistDownloadSheet> createState() => _PlaylistDownloadSheetState();
}

class _PlaylistDownloadSheetState extends State<_PlaylistDownloadSheet> {
  late bool _audioOnly = widget.musicAudioOnly;
  String _quality = '720p';
  DownloadContainer? _container;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return _SheetBody(children: [
      Text(
          widget.musicAudioOnly
              ? locals.musicDownloadAudio
              : locals.downloadPlaylist,
          style: Theme.of(context).textTheme.titleLarge),
      if (widget.musicAudioOnly)
        Text(locals
            .musicDownloadOutput(MusicDownloadFormat.forDatabase(db).label))
      else
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(locals.videoDownloadAudioOnly),
            value: _audioOnly,
            onChanged: (value) => setState(() => _audioOnly = value)),
      _ContainerChoice(
          value: _container,
          audioOnly: _audioOnly,
          musicAudioOnly: widget.musicAudioOnly,
          containers: DownloadContainer.values,
          onChanged: (value) => setState(() => _container = value)),
      if (!_audioOnly)
        _Choice<String>(
            label: locals.quality,
            value: _quality,
            onChanged: (value) => setState(() => _quality = value ?? _quality),
            items: [
              for (final quality in [
                '144p',
                '240p',
                '360p',
                '480p',
                '720p',
                '1080p',
                '1440p',
                '2160p'
              ])
                DropdownMenuItem(value: quality, child: Text(quality)),
            ]),
      Text(widget.musicAudioOnly
          ? locals.musicDownloadQualityHelp
          : locals.downloadPlaylistQualityHelp),
      const SizedBox(height: 16),
      FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(PlaylistDownloadOptions(
              audioOnly: _audioOnly, quality: _quality, container: _container)),
          icon: const Icon(Icons.download),
          label: Text(locals.download)),
    ]);
  }
}
