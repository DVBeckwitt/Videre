import 'package:clipious/music/models/replay_gain.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tagged = ReplayGain(
    trackGainDb: 6,
    trackPeak: 0.5,
    albumGainDb: -6,
    albumPeak: 0.95,
  );

  test('default bypasses tags and tagged modes use their own gain', () {
    expect(musicGainFactor(ReplayGainMode.off, 0, tagged), 1);
    expect(musicGainFactor(ReplayGainMode.track, 0, tagged),
        closeTo(1.995262, 0.000001));
    expect(musicGainFactor(ReplayGainMode.album, 0, tagged),
        closeTo(0.501187, 0.000001));
  });

  test('preamp combines in decibels and respects the selected peak', () {
    expect(musicGainFactor(ReplayGainMode.track, 6, tagged), 2);
    expect(musicGainFactor(ReplayGainMode.album, 12, tagged),
        closeTo(1 / 0.95, 0.000001));
    expect(musicGainFactor(ReplayGainMode.off, 12, tagged), 2);
    expect(musicGainFactor(ReplayGainMode.track, -6, tagged), 1);
  });

  test('unknown headroom prevents boost but still permits attenuation', () {
    expect(musicGainFactor(ReplayGainMode.off, 12, null), 1);
    expect(musicGainFactor(ReplayGainMode.album, 0, null), 1);
    expect(musicGainFactor(ReplayGainMode.track, -6, null),
        closeTo(0.501187, 0.000001));
    expect(
      musicGainFactor(ReplayGainMode.track, 0,
          const ReplayGain(trackGainDb: 6, trackPeak: double.infinity)),
      1,
    );
  });

  test('album mode falls back to track tags when album gain is absent', () {
    const partial = ReplayGain(trackGainDb: 10, trackPeak: 0.8, albumPeak: 1.2);
    expect(musicGainFactor(ReplayGainMode.album, 0, partial), 1.25);
  });
}
