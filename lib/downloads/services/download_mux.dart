import 'dart:async';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

String _inputDemuxer(DownloadedVideo video, MusicDownloadFormat? inputFormat) =>
    switch (inputFormat) {
      MusicDownloadFormat.mp3 => 'mp3',
      MusicDownloadFormat.opus => 'ogg',
      MusicDownloadFormat.m4a => 'mov',
      null => video.container == DownloadContainer.mp4 ? 'mov' : 'matroska',
    };

/// Preserves audio packets at highest quality when the codecs already match.
List<String> musicMuxArguments({
  required String input,
  required String output,
  required DownloadedVideo video,
  MusicDownloadFormat? inputFormat,
  String? sourceCodec,
}) {
  if (path.equals(input, output)) {
    throw ArgumentError('Music export needs a separate output file');
  }
  final demuxer = _inputDemuxer(video, inputFormat);
  final format = video.musicFormat ?? MusicDownloadFormat.mp3;
  final codec = sourceCodec?.trim().toLowerCase() ??
      switch (demuxer) {
        'mp3' => 'mp3',
        'ogg' => 'opus',
        'mov' => 'aac',
        _ => null,
      };
  final target = video.musicPolicy?.quality.targetBitrate;
  final options = switch ((format, target)) {
    (MusicDownloadFormat.mp3, final int rate) => [
        'libmp3lame',
        '-b:a',
        '$rate'
      ],
    (MusicDownloadFormat.opus, final int rate) => [
        'libopus',
        '-b:a',
        '$rate',
        '-vbr',
        'on'
      ],
    (MusicDownloadFormat.m4a, final int rate) => ['aac', '-b:a', '$rate'],
    (MusicDownloadFormat.mp3, null) when codec == 'mp3' => ['copy'],
    (MusicDownloadFormat.mp3, null) => ['libmp3lame', '-q:a', '0'],
    (MusicDownloadFormat.opus, null) when codec == 'opus' => ['copy'],
    (MusicDownloadFormat.opus, null) => [
        'libopus',
        '-b:a',
        '256k',
        '-vbr',
        'on'
      ],
    (MusicDownloadFormat.m4a, null)
        when codec == 'aac' || (codec?.startsWith('mp4a') ?? false) =>
      ['copy'],
    (MusicDownloadFormat.m4a, null) => ['aac', '-b:a', '320k'],
  };
  final metadata = video.musicMetadata;
  String usable(String? value) => value?.replaceAll('\x00', '').trim() ?? '';
  final title = usable(metadata?.title);
  final artist = usable(metadata?.artist);
  final tags = {
    'title': title.isEmpty ? usable(video.title) : title,
    'artist': artist.isEmpty ? usable(video.author) : artist,
    'album': usable(metadata?.album),
  };
  return [
    '-y',
    '-protocol_whitelist',
    'file',
    '-f',
    demuxer,
    '-i',
    input,
    '-map',
    '0:a:0',
    '-c:a',
    ...options,
    '-map_metadata',
    '-1',
    '-map_metadata:s',
    '-1',
    '-map_chapters',
    '-1',
    for (final tag in tags.entries)
      if (tag.value.isNotEmpty) ...['-metadata', '${tag.key}=${tag.value}'],
    '-f',
    switch (format) {
      MusicDownloadFormat.mp3 => 'mp3',
      MusicDownloadFormat.opus => 'opus',
      MusicDownloadFormat.m4a => 'ipod',
    },
    output,
  ];
}

/// Legacy WebM downloads may contain Opus or Vorbis without a recorded codec.
Future<void> runMusicDownloadMux({
  required String input,
  required String output,
  required DownloadedVideo video,
  required CancelToken token,
  MusicDownloadFormat? inputFormat,
  String? sourceCodec,
}) async {
  if (token.isCancelled) throw token.cancelError!;
  if (video.musicFormat == MusicDownloadFormat.opus &&
      video.musicPolicy?.quality.targetBitrate == null &&
      _inputDemuxer(video, inputFormat) == 'matroska' &&
      (sourceCodec == null || sourceCodec.trim().isEmpty)) {
    final session = await FFprobeKit.getMediaInformationFromCommandArguments([
      '-v',
      'error',
      '-of',
      'json',
      '-select_streams',
      'a:0',
      '-show_entries',
      'stream=codec_name',
      '-protocol_whitelist',
      'file',
      '-f',
      'matroska',
      '-i',
      input,
    ]);
    sourceCodec =
        session.getMediaInformation()?.getStreams().firstOrNull?.getCodec();
    if (token.isCancelled) throw token.cancelError!;
    if (sourceCodec == null) {
      throw StateError('Could not identify the audio codec');
    }
  }
  await runDownloadMux(
      musicMuxArguments(
          input: input,
          output: output,
          video: video,
          inputFormat: inputFormat,
          sourceCodec: sourceCodec),
      token);
}

/// Joins native execution before the caller removes the input or output files.
Future<void> runDownloadMux(List<String> args, CancelToken token) async {
  if (token.isCancelled) throw token.cancelError!;
  final session = await FFmpegSession.create(args);
  if (token.isCancelled) throw token.cancelError!;
  if (session.getSessionId() == null) {
    throw StateError('Could not create the download mux session');
  }
  var finished = false;
  Future<void>? cancelling;
  Timer? retry;
  void cancelMux() {
    if (finished || cancelling != null) return;
    cancelling = session.cancel().catchError((Object error) {
      Logger('DownloadMux').fine('Could not cancel the download mux', error);
    }).whenComplete(() => cancelling = null);
  }

  final execution = FFmpegKitConfig.ffmpegExecute(session);
  unawaited(token.whenCancel.then((_) {
    if (finished) return;
    cancelMux();
    // Native startup resets an earlier cancellation flag.
    retry =
        Timer.periodic(const Duration(milliseconds: 100), (_) => cancelMux());
  }));
  try {
    await execution;
  } finally {
    finished = true;
    retry?.cancel();
    await cancelling;
  }
  if (token.isCancelled) throw token.cancelError!;
  if (!((await session.getReturnCode())?.isValueSuccess() ?? false)) {
    throw StateError('Could not mux the download');
  }
}
