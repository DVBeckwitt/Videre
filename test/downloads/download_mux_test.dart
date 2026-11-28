import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/models/music_offline_policy.dart';
import 'package:clipious/downloads/services/download_mux.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:clipious/videos/models/sponsor_segment.dart';
import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const download = DownloadedVideo(
    videoId: 'id',
    title: 'Video title',
    author: 'Channel',
    lengthSeconds: 123,
    quality: 'audio',
    audioOnly: true,
  );

  test('WebM Opus exports copy audio into Ogg with only the selected song tags',
      () {
    final args = musicMuxArguments(
      input: '/tmp/source.webm',
      output: '/tmp/export.ogg',
      sourceCodec: 'Opus',
      video: download.copyWith(
        container: DownloadContainer.webm,
        musicFormat: MusicDownloadFormat.opus,
        musicMetadata: const MusicMetadata(
          title: ' One = "Song" ',
          artist: ' Musicien ',
          album: 'Album\x00',
        ),
      ),
    );
    expect(args, [
      '-y',
      '-protocol_whitelist',
      'file',
      '-f',
      'matroska',
      '-i',
      '/tmp/source.webm',
      '-map',
      '0:a:0',
      '-c:a',
      'copy',
      '-map_metadata',
      '-1',
      '-map_metadata:s',
      '-1',
      '-map_chapters',
      '-1',
      '-metadata',
      'title=One = "Song"',
      '-metadata',
      'artist=Musicien',
      '-metadata',
      'album=Album',
      '-f',
      'opus',
      '/tmp/export.ogg',
    ]);
  });

  test('AAC uses M4A tags and falls back to available video labels', () {
    final args = musicMuxArguments(
      input: '/tmp/source.m4a',
      output: '/tmp/export.m4a',
      video: download.copyWith(
        container: DownloadContainer.mp4,
        musicFormat: MusicDownloadFormat.m4a,
        musicMetadata: const MusicMetadata(title: ' ', artist: '', album: ' '),
      ),
    );
    expect(args, containsAllInOrder(['-f', 'mov', '-i', '/tmp/source.m4a']));
    expect(
        args,
        containsAllInOrder([
          '-c:a',
          'copy',
          'title=Video title',
          'artist=Channel',
          '-f',
          'ipod',
          '/tmp/export.m4a'
        ]));
    expect(args.any((arg) => arg.startsWith('album=')), isFalse);
  });

  test('default MP3 transcodes the source to highest quality LAME VBR', () {
    final args = musicMuxArguments(
      input: '/tmp/source.webm',
      output: '/tmp/song.mp3',
      video: download,
      sourceCodec: 'opus',
    );
    expect(args,
        containsAllInOrder(['-c:a', 'libmp3lame', '-q:a', '0', '-f', 'mp3']));
  });

  test('smaller offline files get the chosen bitrate even for matching codecs',
      () {
    for (final (format, codec, encoder) in [
      (MusicDownloadFormat.mp3, 'mp3', 'libmp3lame'),
      (MusicDownloadFormat.opus, 'opus', 'libopus'),
      (MusicDownloadFormat.m4a, 'aac', 'aac'),
    ]) {
      for (final (quality, bitrate) in [
        (MusicOfflineQuality.balanced, '128000'),
        (MusicOfflineQuality.dataSaver, '64000'),
      ]) {
        final args = musicMuxArguments(
            input: '/tmp/input',
            output: '/tmp/song.${format.extension}',
            inputFormat: format,
            sourceCodec: codec,
            video: download.copyWith(
              musicFormat: format,
              musicPolicy: MusicOfflinePolicy(quality: quality),
            ));
        expect(args, containsAllInOrder(['-c:a', encoder, '-b:a', bitrate]));
      }
    }
  });

  test('AAC and Vorbis can be converted to Opus', () {
    for (final codec in ['aac', 'vorbis']) {
      final args = musicMuxArguments(
          input: '/tmp/input',
          output: '/tmp/song.ogg',
          sourceCodec: codec,
          video: download.copyWith(
              musicFormat: MusicDownloadFormat.opus,
              container: codec == 'aac'
                  ? DownloadContainer.mp4
                  : DownloadContainer.webm));
      expect(
          args,
          containsAllInOrder(
              ['-c:a', 'libopus', '-b:a', '256k', '-f', 'opus']));
    }
  });

  test('private MP3 and Opus can be exported as M4A', () {
    for (final input in [MusicDownloadFormat.mp3, MusicDownloadFormat.opus]) {
      final args = musicMuxArguments(
          input: '/tmp/input',
          output: '/tmp/song.m4a',
          inputFormat: input,
          video: download.copyWith(musicFormat: MusicDownloadFormat.m4a));
      expect(
          args,
          containsAllInOrder([
            '-f',
            input == MusicDownloadFormat.mp3 ? 'mp3' : 'ogg',
            '-c:a',
            'aac',
            '-b:a',
            '320k',
            '-f',
            'ipod'
          ]));
    }
  });

  test('SponsorBlock keeps uncovered audio and re-encodes all export formats',
      () {
    final edit = SponsorAudioEdit(
      sourceDuration: const Duration(seconds: 12),
      categories: {
        SponsorSegmentType.sponsor,
        SponsorSegmentType.musicOffTopic
      },
      segments: [
        SponsorSegment('skip', [3, 5], SponsorSegmentType.sponsor),
        SponsorSegment('skip', [4.5, 6], SponsorSegmentType.musicOffTopic),
        SponsorSegment('skip', [-4, 1], SponsorSegmentType.sponsor),
        SponsorSegment('skip', [11, 15], SponsorSegmentType.sponsor),
        SponsorSegment('skip', [1, 3], SponsorSegmentType.intro),
        SponsorSegment('mute', [7, 8], SponsorSegmentType.sponsor),
        SponsorSegment(
            'skip', [0, double.infinity], SponsorSegmentType.sponsor),
        SponsorSegment('skip', [10, 9], SponsorSegmentType.sponsor),
      ],
    );
    expect(edit.duration, const Duration(seconds: 7));
    expect(edit.timingSignature, '1000000-3000000,6000000-11000000');
    for (final (format, codec, encoder) in [
      (MusicDownloadFormat.mp3, 'mp3', 'libmp3lame'),
      (MusicDownloadFormat.opus, 'opus', 'libopus'),
      (MusicDownloadFormat.m4a, 'aac', 'aac'),
    ]) {
      final args = musicMuxArguments(
          input: '/tmp/input',
          output: '/tmp/song.${format.extension}',
          inputFormat: format,
          sourceCodec: codec,
          edit: edit,
          video: download.copyWith(musicFormat: format));
      expect(args, containsAllInOrder(['-map', '[edited]', '-c:a', encoder]));
      expect(args, isNot(contains('copy')));
      final filter = args[args.indexOf('-filter_complex') + 1];
      expect(filter, contains('atrim=start=1.000000:end=3.000000'));
      expect(filter, contains('atrim=start=6.000000:end=11.000000'));
      expect(filter, endsWith('concat=n=2:v=0:a=1[edited]'));

      final info = (
        duration: const Duration(milliseconds: 7040),
        codec: codec,
        streamCount: 1,
      );
      expect(edit.matchesOutput(info, format), isTrue);
      expect(
          edit.matchesOutput((
            duration: const Duration(seconds: 12),
            codec: codec,
            streamCount: 1,
          ), format),
          isFalse);
      expect(
          edit.matchesOutput((
            duration: info.duration,
            codec: codec,
            streamCount: 2,
          ), format),
          isFalse);
    }
  });

  test(
      'SponsorBlock rejects empty edits and avoids splitting one retained span',
      () {
    SponsorAudioEdit create(List<double> range) => SponsorAudioEdit(
          sourceDuration: const Duration(seconds: 10),
          segments: [SponsorSegment('skip', range, SponsorSegmentType.sponsor)],
          categories: {SponsorSegmentType.sponsor},
        );
    expect(() => create([10, 14]), throwsA(isA<NoSponsorAudioSegments>()));
    expect(() => create([-5, 14]), throwsFormatException);
    final edit = create([2, 14]);
    final args = musicMuxArguments(
        input: '/tmp/input',
        output: '/tmp/song.mp3',
        edit: edit,
        video: download);
    final filter = args[args.indexOf('-filter_complex') + 1];
    expect(edit.duration, const Duration(seconds: 2));
    expect(filter,
        '[0:a:0]asetpts=PTS-STARTPTS,atrim=start=0.000000:end=2.000000,asetpts=PTS-STARTPTS[edited]');
  });

  test('export refuses to replace the source file', () {
    expect(
        () => musicMuxArguments(
            input: '/tmp/file', output: '/tmp/./file', video: download),
        throwsArgumentError);
  });

  test('cancellation before mux skips native session creation', () async {
    final token = CancelToken()..cancel();
    await expectLater(
        runDownloadMux([], token), throwsA(same(token.cancelError)));
  });
}
