import 'dart:math' as math;

enum ReplayGainMode { off, track, album }

const minimumMusicPreampDb = -12.0;
const maximumMusicPreampDb = 12.0;

double clampMusicPreampDb(double db) =>
    db.isFinite ? db.clamp(minimumMusicPreampDb, maximumMusicPreampDb) : 0;

/// Gain in dB and peak amplitude relative to digital full scale.
class ReplayGain {
  const ReplayGain({
    this.trackGainDb,
    this.albumGainDb,
    this.trackPeak,
    this.albumPeak,
  });

  final double? trackGainDb;
  final double? albumGainDb;
  final double? trackPeak;
  final double? albumPeak;
}

/// Calculates an independent decoder gain. The user's volume and transition
/// envelope are still applied by the player downstream.
double musicGainFactor(ReplayGainMode mode, double preampDb, ReplayGain? tags) {
  final preamp = clampMusicPreampDb(preampDb);
  if (mode == ReplayGainMode.off && preamp == 0) return 1;

  final trackGain = tags?.trackGainDb;
  final albumGain = tags?.albumGainDb;
  final useAlbum = mode == ReplayGainMode.album && albumGain?.isFinite == true;
  final gain = switch (mode) {
    ReplayGainMode.off => 0.0,
    ReplayGainMode.album when useAlbum => albumGain!,
    _ => trackGain?.isFinite == true ? trackGain! : 0.0,
  };
  final trackPeak = _validPeak(tags?.trackPeak);
  final albumPeak = _validPeak(tags?.albumPeak);
  final peak = useAlbum
      ? math.max(albumPeak ?? 1.0, trackPeak ?? 0.0)
      : trackPeak ?? 1.0;

  // The ReplayGain peak is a sample amplitude, so 1 / peak is the largest
  // scaling factor that fits below full scale. Untagged audio assumes 1.0.
  // Limit exceptionally large factors from corrupt or unconventional tags.
  final requested = math.pow(10, (gain + preamp) / 20).toDouble();
  return math.min(requested, math.min(1 / peak, 16.0));
}

double? _validPeak(double? value) =>
    value != null && value.isFinite && value > 0 ? value : null;
