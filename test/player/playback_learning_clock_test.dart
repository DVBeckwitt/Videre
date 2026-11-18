import 'package:clipious/player/models/playback_learning_clock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('credits actual elapsed playing time including background samples', () {
    final clock = PlaybackLearningClock();
    clock.sample(Duration.zero, 0);
    clock.sample(const Duration(seconds: 1), 1000000);
    clock.sample(const Duration(seconds: 31), 31000000);
    expect(clock.played, const Duration(seconds: 31));
  });

  test('SponsorBlock and user seek jumps are not listened time', () {
    final clock = PlaybackLearningClock();
    clock.sample(Duration.zero, 0);
    clock.sample(const Duration(seconds: 1), 1000000);
    clock.interrupt();
    clock.sample(const Duration(minutes: 3), 2000000);
    clock.sample(const Duration(minutes: 3, seconds: 1), 3000000);
    expect(clock.played, const Duration(seconds: 2));
  });

  test('buffering, paused time and stationary progress do not count', () {
    final clock = PlaybackLearningClock();
    clock.sample(Duration.zero, 0);
    clock.sample(Duration.zero, 30000000);
    clock.interrupt();
    clock.sample(const Duration(seconds: 1), 60000000);
    clock.sample(const Duration(seconds: 2), 61000000);
    expect(clock.played, const Duration(seconds: 1));
  });

  test('speed changes cannot inflate wall-clock consumption', () {
    final clock = PlaybackLearningClock();
    clock.sample(Duration.zero, 0, speed: 2);
    clock.sample(const Duration(seconds: 2), 1000000, speed: 0.5);
    clock.sample(const Duration(milliseconds: 2500), 2000000, speed: 0.5);
    expect(clock.played, const Duration(seconds: 2));
  });

  test('unreported stalled intervals and backward samples are conservative',
      () {
    final clock = PlaybackLearningClock();
    clock.sample(Duration.zero, 0);
    clock.sample(const Duration(seconds: 1), 10000000);
    clock.sample(Duration.zero, 11000000);
    expect(clock.played, const Duration(seconds: 1));
  });
}
