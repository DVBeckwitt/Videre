import 'dart:async';
import 'dart:io';

import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'download_space.dart';

String _inputDemuxer(DownloadedVideo video, MusicDownloadFormat? inputFormat) =>
    switch (inputFormat) {
      MusicDownloadFormat.mp3 => 'mp3',
      MusicDownloadFormat.opus => 'ogg',
      MusicDownloadFormat.m4a => 'mov',
      null => video.container == DownloadContainer.mp4 ? 'mov' : 'matroska',
    };

typedef _AudioRange = ({int start, int end});

class NoSponsorAudioSegments implements Exception {
  const NoSponsorAudioSegments();
}

/// Retained spans on the actual local audio timeline, in microseconds.
class SponsorAudioEdit {
  static const _maxSegments = 128;
  final List<_AudioRange> _keep;
  final Duration duration;

  SponsorAudioEdit._(this._keep, this.duration);

  factory SponsorAudioEdit({
    required Duration sourceDuration,
    required Iterable<SponsorSegment> segments,
    required Set<SponsorSegmentType> categories,
  }) {
    final end = sourceDuration.inMicroseconds;
    if (end <= 0) throw const FormatException('Invalid audio duration');
    int boundary(double seconds) =>
        (seconds.clamp(0, end / Duration.microsecondsPerSecond) *
                Duration.microsecondsPerSecond)
            .round();
    final cuts = <_AudioRange>[];
    for (final segment in segments) {
      final times = segment.segment;
      if (segment.actionType != 'skip' ||
          !categories.contains(segment.category) ||
          times.length != 2 ||
          !times.every((time) => time.isFinite)) {
        continue;
      }
      final start = boundary(times.first);
      final finish = boundary(times.last);
      if (finish > start) cuts.add((start: start, end: finish));
      if (cuts.length > _maxSegments) {
        throw const FormatException('Too many saved audio segments');
      }
    }
    if (cuts.isEmpty) throw const NoSponsorAudioSegments();
    cuts.sort((a, b) => a.start.compareTo(b.start));
    final keep = <_AudioRange>[];
    var cursor = 0;
    for (final cut in cuts) {
      if (cut.start > cursor) keep.add((start: cursor, end: cut.start));
      if (cut.end > cursor) cursor = cut.end;
    }
    if (cursor < end) keep.add((start: cursor, end: end));
    if (keep.isEmpty) {
      throw const FormatException(
          'Saved segments would remove the entire song');
    }
    return SponsorAudioEdit._(
        keep,
        Duration(
            microseconds:
                keep.fold(0, (sum, span) => sum + span.end - span.start)));
  }

  String get timingSignature =>
      _keep.map((span) => '${span.start}-${span.end}').join(',');

  String get _filter {
    String seconds(int time) =>
        (time / Duration.microsecondsPerSecond).toStringAsFixed(6);
    final count = _keep.length;
    final graph = <String>[
      if (count > 1)
        '[0:a:0]asetpts=PTS-STARTPTS,asplit=$count'
            '${List.generate(count, (index) => '[part$index]').join()}',
      for (var index = 0; index < count; index++)
        '${count == 1 ? '[0:a:0]asetpts=PTS-STARTPTS,' : '[part$index]'}'
            'atrim=start=${seconds(_keep[index].start)}:end=${seconds(_keep[index].end)},'
            'asetpts=PTS-STARTPTS[${count == 1 ? 'edited' : 'keep$index'}]',
      if (count > 1)
        '${List.generate(count, (index) => '[keep$index]').join()}'
            'concat=n=$count:v=0:a=1[edited]',
    ];
    return graph.join(';');
  }

  bool matchesOutput(AudioExportInfo info, MusicDownloadFormat format) {
    final codec = switch (format) {
      MusicDownloadFormat.mp3 => 'mp3',
      MusicDownloadFormat.opus => 'opus',
      MusicDownloadFormat.m4a => 'aac',
    };
    // Container durations include encoder delay and padding.
    return info.streamCount == 1 &&
        info.codec == codec &&
        info.duration > Duration.zero &&
        (info.duration - duration).abs() <= const Duration(milliseconds: 150);
  }
}

typedef AudioExportInfo = ({Duration duration, String codec, int streamCount});
typedef AudioExportProbe = Future<AudioExportInfo> Function(
    String input, DownloadedVideo audio, CancelToken token);

Future<AudioExportInfo> probeAudioExport(
    String input, DownloadedVideo audio, CancelToken token) async {
  if (token.isCancelled) throw token.cancelError!;
  if (await File(input).length() <= 0) {
    throw const FormatException('Empty audio export file');
  }
  final session = await FFprobeKit.getMediaInformationFromCommandArguments([
    '-v',
    'error',
    '-of',
    'json',
    '-show_format',
    '-show_streams',
    '-protocol_whitelist',
    'file',
    '-f',
    _inputDemuxer(audio, audio.musicFormat),
    '-i',
    input,
  ]);
  if (token.isCancelled) throw token.cancelError!;
  final parsed = session.getMediaInformation();
  final duration = double.tryParse(parsed?.getDuration() ?? '');
  final streams = parsed?.getStreams() ?? const [];
  final codec = streams
      .where((stream) => stream.getType() == 'audio')
      .firstOrNull
      ?.getCodec();
  if (!((await session.getReturnCode())?.isValueSuccess() ?? false) ||
      duration == null ||
      !duration.isFinite ||
      duration <= 0 ||
      duration > const Duration(days: 7).inSeconds ||
      codec == null ||
      codec.isEmpty) {
    throw const FormatException('Could not verify the local audio file');
  }
  return (
    duration: Duration(
        microseconds: (duration * Duration.microsecondsPerSecond).round()),
    codec: codec,
    streamCount: streams.length,
  );
}

/// Preserves audio packets at highest quality when the codecs already match.
List<String> musicMuxArguments({
  required String input,
  required String output,
  required DownloadedVideo video,
  MusicDownloadFormat? inputFormat,
  String? sourceCodec,
  SponsorAudioEdit? edit,
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
    (MusicDownloadFormat.mp3, null) when edit == null && codec == 'mp3' => [
        'copy'
      ],
    (MusicDownloadFormat.mp3, null) => ['libmp3lame', '-q:a', '0'],
    (MusicDownloadFormat.opus, null) when edit == null && codec == 'opus' => [
        'copy'
      ],
    (MusicDownloadFormat.opus, null) => [
        'libopus',
        '-b:a',
        '256k',
        '-vbr',
        'on'
      ],
    (MusicDownloadFormat.m4a, null)
        when edit == null &&
            (codec == 'aac' || (codec?.startsWith('mp4a') ?? false)) =>
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
    if (edit != null) ...['-filter_complex', edit._filter],
    '-map',
    edit == null ? '0:a:0' : '[edited]',
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
    String? output;
    try {
      output = await session.getAllLogsAsString(500);
    } catch (_) {
      // Preserve the original mux failure if native logs are unavailable.
    }
    if (output?.contains('No space left on device') ?? false) {
      throw const DownloadInsufficientSpace();
    }
    throw StateError('Could not mux the download');
  }
}
