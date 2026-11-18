import 'package:clipious/downloads/models/download_formats.dart';
import 'package:clipious/downloads/models/downloaded_video.dart';
import 'package:clipious/downloads/models/music_download_format.dart';
import 'package:clipious/downloads/services/download_mux.dart';
import 'package:clipious/videos/models/music_metadata.dart';
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
