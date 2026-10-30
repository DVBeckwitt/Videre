import 'dart:math' as math;

const minimumPitchSemitones = -12;
const maximumPitchSemitones = 12;

int clampPitchSemitones(int semitones) =>
    semitones.clamp(minimumPitchSemitones, maximumPitchSemitones);

double pitchFactorForSemitones(int semitones) =>
    math.pow(2, clampPitchSemitones(semitones) / 12).toDouble();

/// Native pitch is a frequency ratio; UI changes are whole semitones.
int? semitonesForPitchFactor(Object? value) {
  if (value is! num || !value.isFinite || value < 0.5 || value > 2) {
    return null;
  }
  return clampPitchSemitones((12 * math.log(value) / math.ln2).round());
}
