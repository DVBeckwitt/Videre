import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/db/settings.dart';

import '../models/replay_gain.dart';

export 'android_music_output.dart' show MusicOutput, androidMusicOutputs;

typedef OutputGain = ({ReplayGainMode mode, double preampDb});

class MusicOutputPreset {
  MusicOutputPreset(this.enabled, Map<double, double> gains,
      {this.gain, this.untaggedPreampDb})
      : gains = Map.unmodifiable(gains);

  final bool? enabled;
  final Map<double, double> gains;
  final OutputGain? gain;
  final double? untaggedPreampDb;

  static MusicOutputPreset? _decode(String? saved) {
    if (saved == null) return null;
    try {
      final value = jsonDecode(saved);
      if (value is! Map ||
          (value['enabled'] != null && value['enabled'] is! bool) ||
          value['gains'] is! Map) {
        return null;
      }
      final gains = <double, double>{};
      for (final band in (value['gains'] as Map).entries) {
        final frequency = double.tryParse(band.key.toString());
        final gain = band.value;
        if (frequency == null ||
            !frequency.isFinite ||
            frequency <= 0 ||
            gain is! num ||
            !gain.isFinite) {
          return null;
        }
        gains[frequency] = gain.toDouble();
      }
      final mode = ReplayGainMode.values.asNameMap()[value['replayGain']];
      final preamp = value['preampDb'];
      final untagged = value['untaggedPreampDb'];
      final outputGain = mode == null || preamp is! num || !preamp.isFinite
          ? null
          : (mode: mode, preampDb: clampMusicPreampDb(preamp.toDouble()));
      return MusicOutputPreset(
        value['enabled'] as bool?,
        gains,
        gain: outputGain,
        untaggedPreampDb: untagged is num && untagged.isFinite
            ? clampMusicPreampDb(untagged.toDouble())
            : null,
      );
    } on FormatException {
      return null;
    }
  }

  String _encode() => jsonEncode({
        'enabled': enabled,
        if (gain case final outputGain?) ...{
          'replayGain': outputGain.mode.name,
          'preampDb': outputGain.preampDb,
          if (untaggedPreampDb != null) 'untaggedPreampDb': untaggedPreampDb,
        },
        'gains': gains.map((frequency, gain) => MapEntry('$frequency', gain)),
      });
}

class MusicOutputPresetStore {
  const MusicOutputPresetStore();

  // One local setting per route keeps unrelated route writes independent.
  String _key(String outputId) => 'musicOutputPreset.v1.$outputId';

  MusicOutputPreset? read(String profileId, String outputId) =>
      MusicOutputPreset._decode(
        db.forProfile(profileId).getSettings(_key(outputId))?.value,
      );

  Future<void> write(
    String profileId,
    String outputId,
    MusicOutputPreset? preset,
  ) async {
    final owner = db.forProfile(profileId);
    final key = _key(outputId);
    if (preset == null) {
      await owner.deleteSetting(key);
    } else {
      await owner.saveSetting(SettingsValue(key, preset._encode()));
    }
  }
}
