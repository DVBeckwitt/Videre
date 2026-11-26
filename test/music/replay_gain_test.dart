import 'package:clipious/music/models/replay_gain.dart';
import 'package:flutter_test/flutter_test.dart';

// Profiles upgraded from one preamp use the same value for both settings.
double gainWithSharedPreamp(
        ReplayGainMode mode, double preamp, ReplayGain? tags,
        {bool albumContext = false}) =>
    musicGainFactor(mode, tags,
        taggedPreampDb: preamp,
        untaggedPreampDb: preamp,
        albumContext: albumContext);

void main() {
  const tagged = ReplayGain(
    trackGainDb: 6,
    trackPeak: 0.5,
    albumGainDb: -6,
    albumPeak: 0.95,
  );

  test('the preamp follows the gain resolved by the active mode', () {
    double factor(ReplayGainMode mode, ReplayGain? tags,
            {bool albumContext = false}) =>
        musicGainFactor(mode, tags,
            taggedPreampDb: -6,
            untaggedPreampDb: -12,
            albumContext: albumContext);

    const zeroGain = ReplayGain(trackGainDb: 0);
    const albumOnly = ReplayGain(albumGainDb: 6);
    const invalidGain = ReplayGain(
      trackGainDb: double.infinity,
      albumGainDb: double.nan,
      trackPeak: 0.5,
    );
    const trackFallback = ReplayGain(trackGainDb: 6, albumGainDb: double.nan);
    const untaggedFactor = 0.251189;

    expect(factor(ReplayGainMode.track, tagged), 1);
    expect(factor(ReplayGainMode.track, zeroGain), closeTo(0.501187, 0.000001));
    expect(
        factor(ReplayGainMode.track, null), closeTo(untaggedFactor, 0.000001));
    expect(factor(ReplayGainMode.album, invalidGain),
        closeTo(untaggedFactor, 0.000001));
    expect(factor(ReplayGainMode.contextual, trackFallback, albumContext: true),
        1);
    expect(factor(ReplayGainMode.contextual, albumOnly, albumContext: true), 1);
    expect(factor(ReplayGainMode.contextual, albumOnly),
        closeTo(untaggedFactor, 0.000001));
    expect(
        factor(ReplayGainMode.off, tagged), closeTo(untaggedFactor, 0.000001));
  });

  test('default bypasses tags and tagged modes use their own gain', () {
    expect(gainWithSharedPreamp(ReplayGainMode.off, 0, tagged), 1);
    expect(gainWithSharedPreamp(ReplayGainMode.track, 0, tagged),
        closeTo(1.995262, 0.000001));
    expect(gainWithSharedPreamp(ReplayGainMode.album, 0, tagged),
        closeTo(0.501187, 0.000001));
  });

  test('preamp combines in decibels and respects the selected peak', () {
    expect(gainWithSharedPreamp(ReplayGainMode.track, 6, tagged), 2);
    expect(gainWithSharedPreamp(ReplayGainMode.album, 12, tagged),
        closeTo(1 / 0.95, 0.000001));
    expect(gainWithSharedPreamp(ReplayGainMode.off, 12, tagged), 2);
    expect(gainWithSharedPreamp(ReplayGainMode.track, -6, tagged), 1);
  });

  test('unknown headroom prevents boost but still permits attenuation', () {
    expect(gainWithSharedPreamp(ReplayGainMode.off, 12, null), 1);
    expect(gainWithSharedPreamp(ReplayGainMode.album, 0, null), 1);
    expect(gainWithSharedPreamp(ReplayGainMode.track, -6, null),
        closeTo(0.501187, 0.000001));
    expect(
      gainWithSharedPreamp(ReplayGainMode.track, 0,
          const ReplayGain(trackGainDb: 6, trackPeak: double.infinity)),
      1,
    );
  });

  test('album mode falls back to track tags when album gain is absent', () {
    const partial = ReplayGain(trackGainDb: 10, trackPeak: 0.8, albumPeak: 1.2);
    expect(gainWithSharedPreamp(ReplayGainMode.album, 0, partial), 1.25);
  });

  test('contextual mode uses the selected gain and peak with preamp', () {
    expect(gainWithSharedPreamp(ReplayGainMode.contextual, 12, tagged), 2);
    expect(
        gainWithSharedPreamp(ReplayGainMode.contextual, 12, tagged,
            albumContext: true),
        closeTo(1 / 0.95, 0.000001));
  });

  test('contextual album gain falls back with absent or invalid tags', () {
    const partial = ReplayGain(
        albumGainDb: double.nan,
        trackGainDb: 6,
        trackPeak: 0.8,
        albumPeak: 1.2);
    expect(
        gainWithSharedPreamp(ReplayGainMode.contextual, 0, partial,
            albumContext: true),
        1.25);
    expect(
        gainWithSharedPreamp(ReplayGainMode.contextual, -6, null,
            albumContext: true),
        closeTo(0.501187, 0.000001));
  });
}
