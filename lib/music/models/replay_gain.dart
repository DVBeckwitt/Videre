import 'dart:math' as math;

enum ReplayGainMode { off, track, album, contextual }

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

/// Calculates decoder gain using the preamp for the resolved adjustment.
/// The player's volume and transition envelope are applied downstream.
double musicGainFactor(
  ReplayGainMode mode,
  ReplayGain? tags, {
  required double taggedPreampDb,
  required double untaggedPreampDb,
  bool albumContext = false,
}) {
  final trackGain = tags?.trackGainDb;
  final albumGain = tags?.albumGainDb;
  final useAlbum = (mode == ReplayGainMode.album ||
          (mode == ReplayGainMode.contextual && albumContext)) &&
      albumGain?.isFinite == true;
  final gain = switch (mode) {
    ReplayGainMode.off => null,
    _ when useAlbum => albumGain!,
    _ => trackGain?.isFinite == true ? trackGain : null,
  };
  final preamp =
      clampMusicPreampDb(gain == null ? untaggedPreampDb : taggedPreampDb);
  if (mode == ReplayGainMode.off && preamp == 0) return 1;

  final trackPeak = _validPeak(tags?.trackPeak);
  final albumPeak = _validPeak(tags?.albumPeak);
  final peak = useAlbum
      ? math.max(albumPeak ?? 1.0, trackPeak ?? 0.0)
      : trackPeak ?? 1.0;

  // The ReplayGain peak is a sample amplitude, so 1 / peak is the largest
  // scaling factor that fits below full scale. Unknown peaks assume 1.0.
  // Limit exceptionally large factors from corrupt or unconventional tags.
  final requested = math.pow(10, ((gain ?? 0) + preamp) / 20).toDouble();
  return math.min(requested, math.min(1 / peak, 16.0));
}

double? _validPeak(double? value) =>
    value != null && value.isFinite && value > 0 ? value : null;
