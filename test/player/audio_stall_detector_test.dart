import 'package:clipious/player/models/audio_stall_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

NativePlaybackProgress _sample(
  int at, {
  int position = 10250,
  int buffer = 15000,
  int? duration = 120000,
  int revision = 1,
  bool playWhenReady = true,
  bool isPlaying = true,
  ProcessingState processing = ProcessingState.ready,
  int suppression = 0,
  bool seeking = false,
  bool error = false,
}) =>
    NativePlaybackProgress(
      position: Duration(milliseconds: position),
      bufferedPosition: Duration(milliseconds: buffer),
      duration: duration == null ? null : Duration(milliseconds: duration),
      sampledAtMillis: at,
      sourceRevision: revision,
      playWhenReady: playWhenReady,
      isPlaying: isPlaying,
      processingState: processing,
      suppressionReason: suppression,
      seekPending: seeking,
      hasError: error,
    );

void _arm(AudioStallDetector detector) {
  expect(
      detector.observe(_sample(0, position: 10000), eligible: true), isFalse);
  expect(detector.observe(_sample(2000), eligible: true), isFalse);
}

void main() {
  test('reports a buffered ready stall after 20 seconds, once', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at < 22000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), isFalse);
    }
    expect(detector.observe(_sample(22000), eligible: true), isTrue);
    expect(detector.observe(_sample(24000), eligible: true), isFalse);
    expect(
        detector.observe(_sample(26000, playWhenReady: false), eligible: true),
        isFalse);
    for (var at = 28000; at <= 52000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), isFalse);
    }
  });

  test('ready buffer growth cannot disguise a frozen native position', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 22000; at += 2000) {
      expect(detector.observe(_sample(at, buffer: 15000 + at), eligible: true),
          at == 22000);
    }
  });

  test('never classifies startup without actual native advancement', () {
    final detector = AudioStallDetector();
    for (var at = 0; at <= 90000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), isFalse);
    }
  });

  test('requires 250 milliseconds of cumulative native progress', () {
    final detector = AudioStallDetector();
    for (var index = 0; index < 5; index++) {
      expect(
          detector.observe(_sample(index * 2000, position: 10000 + index * 50),
              eligible: true),
          isFalse);
    }
    for (var at = 10000; at <= 30000; at += 2000) {
      expect(detector.observe(_sample(at, position: 10200), eligible: true),
          isFalse);
    }
    expect(detector.observe(_sample(32000), eligible: true), isFalse);
    for (var at = 34000; at <= 52000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 52000);
    }
  });

  test(
      'observes progress even before enough audio is buffered for ready checks',
      () {
    final detector = AudioStallDetector();
    expect(
        detector.observe(_sample(0, position: 10000, buffer: 11000),
            eligible: true),
        isFalse);
    expect(detector.observe(_sample(2000, buffer: 11000), eligible: true),
        isFalse);
    for (var at = 4000; at <= 24000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 24000);
    }
  });

  test('advancing playback never stalls', () {
    final detector = AudioStallDetector();
    for (var at = 0; at <= 90000; at += 2000) {
      expect(
          detector.observe(_sample(at, position: at, buffer: at + 5000),
              eligible: true),
          isFalse);
    }
  });

  test(
      'buffering requires 60 continuous seconds without position or buffer gain',
      () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 64000; at += 2000) {
      expect(
          detector.observe(
              _sample(at,
                  processing: ProcessingState.buffering, isPlaying: false),
              eligible: true),
          at == 64000);
    }
  });

  test('slow buffer growth keeps buffering recovery from firing', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 124000; at += 2000) {
      expect(
          detector.observe(
              _sample(at,
                  buffer: 15000 + at ~/ 10,
                  processing: ProcessingState.buffering,
                  isPlaying: false),
              eligible: true),
          isFalse);
    }
  });

  test('position movement while buffering restarts its grace period', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 84000; at += 2000) {
      expect(
          detector.observe(
              _sample(at,
                  position: at < 40000 ? 10250 : 10500,
                  processing: ProcessingState.buffering,
                  isPlaying: false),
              eligible: true),
          isFalse);
    }
  });

  for (final (name, interrupt, eligible)
      in <(String, NativePlaybackProgress, bool)>[
    ('paused', _sample(20000, playWhenReady: false), true),
    ('suppressed', _sample(20000, suppression: 1), true),
    ('seeking', _sample(20000, seeking: true), true),
    ('loading', _sample(20000, processing: ProcessingState.loading), true),
    ('idle', _sample(20000, processing: ProcessingState.idle), true),
    ('ended', _sample(20000, processing: ProcessingState.completed), true),
    ('failed', _sample(20000, error: true), true),
    ('not playing', _sample(20000, isPlaying: false), true),
    ('unbuffered', _sample(20000, buffer: 11000), true),
    ('near end', _sample(20000, duration: 12250), true),
    ('offline or replaced', _sample(20000), false),
  ]) {
    test('$name interrupts the ready stall baseline', () {
      final detector = AudioStallDetector();
      _arm(detector);
      for (var at = 4000; at < 20000; at += 2000) {
        expect(detector.observe(_sample(at), eligible: true), isFalse);
      }
      expect(detector.observe(interrupt, eligible: eligible), isFalse);
      for (var at = 22000; at <= 42000; at += 2000) {
        expect(detector.observe(_sample(at), eligible: true), at == 42000);
      }
    });
  }

  test('buffering near the end does not restart finished content', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 84000; at += 2000) {
      expect(
          detector.observe(
              _sample(at,
                  duration: 12250,
                  processing: ProcessingState.buffering,
                  isPlaying: false),
              eligible: true),
          isFalse);
    }
  });

  test('a missing sample gap never contributes to a stall', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 18000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), isFalse);
    }
    for (var at = 30000; at <= 50000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 50000);
    }
  });

  test(
      'late samples and older source revisions cannot replace current evidence',
      () {
    final detector = AudioStallDetector();
    _arm(detector);
    expect(detector.observe(_sample(4000), eligible: true), isFalse);
    expect(detector.observe(_sample(2000, position: 70000), eligible: true),
        isFalse);
    expect(
        detector.observe(_sample(5000, revision: 0), eligible: true), isFalse);
    expect(detector.observe(_sample(4000), eligible: true), isFalse);
    for (var at = 6000; at <= 22000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 22000);
    }
  });

  for (final processing in [ProcessingState.ready, ProcessingState.buffering]) {
    test('replacement $processing source must prove its own advancement', () {
      final detector = AudioStallDetector();
      _arm(detector);
      final lastStatic = processing == ProcessingState.ready ? 30000 : 70000;
      for (var at = 4000; at <= lastStatic; at += 2000) {
        expect(
            detector.observe(
                _sample(at,
                    revision: 2,
                    position: 20000,
                    buffer: 25000,
                    processing: processing,
                    isPlaying: processing == ProcessingState.ready),
                eligible: true),
            isFalse);
      }
      expect(
          detector.observe(
              _sample(lastStatic + 2000,
                  revision: 2, position: 20000, buffer: 25000),
              eligible: true),
          isFalse);
      for (var at = lastStatic + 4000; at <= lastStatic + 24000; at += 2000) {
        expect(
            detector.observe(
                _sample(at, revision: 2, position: 20250, buffer: 25000),
                eligible: true),
            at == lastStatic + 24000);
      }
    });
  }

  test('mode switches start a separate grace period', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at < 60000; at += 2000) {
      expect(
          detector.observe(
              _sample(at,
                  processing: ProcessingState.buffering, isPlaying: false),
              eligible: true),
          isFalse);
    }
    for (var at = 60000; at <= 80000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 80000);
    }
  });

  test('backwards native discontinuity resets the baseline', () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at < 20000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), isFalse);
    }
    for (var at = 20000; at <= 40000; at += 2000) {
      expect(detector.observe(_sample(at, position: 5000), eligible: true),
          at == 40000);
    }
  });

  test('explicit seek reset does not mistake its target for playback progress',
      () {
    final detector = AudioStallDetector();
    expect(detector.observe(_sample(0, position: 0), eligible: true), isFalse);
    detector.reset(forgetProgress: true);
    for (var at = 2000; at <= 30000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), isFalse);
    }
  });

  test(
      'reset rearms recovery, while a new occurrence must prove progress again',
      () {
    final detector = AudioStallDetector();
    _arm(detector);
    for (var at = 4000; at <= 22000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 22000);
    }
    detector.reset();
    for (var at = 24000; at <= 44000; at += 2000) {
      expect(detector.observe(_sample(at), eligible: true), at == 44000);
    }
    detector.reset(forgetProgress: true);
    for (var at = 0; at <= 30000; at += 2000) {
      expect(
          detector.observe(_sample(at, revision: 0), eligible: true), isFalse);
    }
  });
}
