import 'package:clipious/music/services/music_waveform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.github.dvbeckwitt.videre/music_waveform');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final source =
      (uri: Uri.file('/downloads/quiet-loud.wav'), startUs: 0, endUs: 8000000);
  final peaks = List.generate(256, (i) => i < 128 ? 0.125 : 0.75);

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reuses peaks by profile, clip and freshly checked revision', () async {
    final waveforms = MusicWaveforms();
    var revision = 'original';
    final extracts = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'revision':
          return revision;
        case 'extract':
          extracts.add(call);
          return peaks;
        default:
          fail('Unexpected call ${call.method}');
      }
    });

    expect(await waveforms.load('a', source).peaks, peaks);
    expect(await waveforms.load('a', source).peaks, peaks);
    expect(extracts, hasLength(1));
    expect(extracts.single.arguments, containsPair('endUs', 8000000));
    expect(extracts.single.arguments,
        containsPair('expectedRevision', 'original'));

    final shorter = (uri: source.uri, startUs: 0, endUs: 4000000);
    expect(await waveforms.load('a', shorter).peaks, peaks);
    expect(await waveforms.load('b', source).peaks, peaks);
    revision = 'replacement';
    expect(await waveforms.load('a', source).peaks, peaks);
    expect(extracts, hasLength(4));
  });

  test('discards a result if the file revision changed during analysis',
      () async {
    final waveforms = MusicWaveforms();
    var revision = 'original';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'revision') return revision;
      expect(call.method, 'extract');
      revision = 'replacement';
      return peaks;
    });

    expect(await waveforms.load('a', source).peaks, isNull);
    expect(await waveforms.load('a', source).peaks, peaks);
  });

  test('unversioned documents can draw but their results are not reused',
      () async {
    final waveforms = MusicWaveforms();
    var extracts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'revision') return null;
      expect(call.method, 'extract');
      extracts++;
      return peaks;
    });

    expect(await waveforms.load('a', source).peaks, peaks);
    expect(await waveforms.load('a', source).peaks, peaks);
    expect(extracts, 2);
  });

  test('a network source never invokes the native analysis channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('Unexpected call ${call.method}');
    });
    final remote =
        (uri: Uri.https('example.com', '/song'), startUs: null, endUs: null);
    expect(await MusicWaveforms().load('a', remote).peaks, isNull);
  });
}
