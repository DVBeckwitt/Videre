import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/replay_gain.dart';
import 'music_output_presets.dart';
import 'music_replay_gain_preferences.dart';

class MusicEqualizerBand {
  final int index;
  final double frequency;
  final double gain;

  const MusicEqualizerBand(this.index, this.frequency, this.gain);
}

class MusicEqualizerParameters {
  final double minimum;
  final double maximum;
  final List<MusicEqualizerBand> bands;

  const MusicEqualizerParameters(this.minimum, this.maximum, this.bands);
}

/// An optional effect bound to one decoder's actual Android audio session.
abstract class MusicEqualizerBackend {
  int? get sessionId;
  Stream<int?> get sessions;
  Future<MusicEqualizerParameters> read(int session);
  Future<void> setEnabled(bool value, int session);
  Future<void> setGain(int band, double gain, int session);
}

class _JustAudioEqualizer implements MusicEqualizerBackend {
  final AudioPlayer player;
  _JustAudioEqualizer(this.player);

  @override
  int? get sessionId => player.androidAudioSessionId;
  @override
  Stream<int?> get sessions => player.androidAudioSessionIdStream;
  @override
  Future<MusicEqualizerParameters> read(int session) async {
    final parameters =
        await player.getAndroidEqualizerParameters(expectedSessionId: session);
    return MusicEqualizerParameters(
        parameters.minDecibels, parameters.maxDecibels, [
      for (final band in parameters.bands)
        MusicEqualizerBand(band.index, band.centerFrequency, band.gain)
    ]);
  }

  @override
  Future<void> setEnabled(bool value, int session) =>
      player.setAndroidEqualizerEnabled(value, expectedSessionId: session);
  @override
  Future<void> setGain(int band, double gain, int session) => player
      .setAndroidEqualizerBandGain(band, gain, expectedSessionId: session);
}

typedef _OutputGain = ({
  ReplayGainMode mode,
  double taggedPreampDb,
  double untaggedPreampDb,
});

/// Applies EQ only to the active Music decoder. A verified output can restore a
/// locally saved Sound preset. Otherwise ReplayGain uses the profile defaults.
class MusicSoundController extends ChangeNotifier {
  MusicSoundController({
    bool? supported,
    String Function()? currentProfile,
    MusicOutputPresetStore outputPresets = const MusicOutputPresetStore(),
  })  : supported = supported ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
        _currentProfile = currentProfile ?? (() => db.profileId),
        _outputPresets = outputPresets;

  final bool supported;
  final String Function() _currentProfile;
  final MusicOutputPresetStore _outputPresets;
  MusicEqualizerBackend? _backend;
  Object? _owner;
  String? _profile;
  StreamSubscription<int?>? _subscription;
  Stream<MusicOutput?>? _outputSource;
  StreamSubscription<MusicOutput?>? _outputSubscription;
  MusicOutput? _output;
  bool _restoreOutput = false;
  MusicOutputPreset? _savedOutputPreset;
  _OutputGain? _outputGain;
  int _outputSelection = 0;
  bool _outputPresetFailed = false;
  bool _savingOutputPreset = false;
  ({MusicEqualizerBackend backend, int session, Future<void> done})? _operation;
  int? _session;
  int _revision = 0;
  bool _disposed = false;
  bool _opened = false;
  bool _busy = false;
  bool _failed = false;
  bool _enabled = false;
  MusicEqualizerParameters? _parameters;
  final Map<double, double> _desiredGains = {};

  MusicEqualizerParameters? get parameters => _parameters;
  int get revision => _revision;
  bool get busy => _busy;
  bool get failed => _failed;
  bool get enabled => _enabled;
  bool get waiting => supported && (_session == null || _session! <= 0);
  bool get available => supported && _parameters != null && !_failed;
  MusicOutput? get output => _output;
  bool get hasOutputPreset => _savedOutputPreset != null;
  bool get outputPresetFailed => _outputPresetFailed;
  bool get savingOutputPreset => _savingOutputPreset;

  bool get replayGainSupported => supported;
  _OutputGain? get _activeOutputGain =>
      _profile == _currentProfile() ? _outputGain : null;

  ReplayGainMode get replayGainMode => replayGainSupported
      ? _activeOutputGain?.mode ?? _replayGainPreferences.mode
      : ReplayGainMode.off;
  double get musicTaggedPreampDb => replayGainSupported
      ? _activeOutputGain?.taggedPreampDb ??
          _replayGainPreferences.taggedPreampDb
      : 0;
  double get musicUntaggedPreampDb => replayGainSupported
      ? _activeOutputGain?.untaggedPreampDb ??
          _replayGainPreferences.untaggedPreampDb
      : 0;

  MusicReplayGainPreferences get _replayGainPreferences =>
      MusicReplayGainPreferences(db.forProfile(db.profileId));

  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    if (_disposed || !replayGainSupported) return;
    if (_output != null && _profile == _currentProfile()) {
      _outputGain = (
        mode: mode,
        taggedPreampDb: musicTaggedPreampDb,
        untaggedPreampDb: musicUntaggedPreampDb,
      );
      _notify();
    } else {
      await _saveReplayGain((preferences) => preferences.setMode(mode));
    }
  }

  Future<void> setMusicTaggedPreampDb(double value) =>
      _setMusicPreampDb(value, tagged: true);

  Future<void> setMusicUntaggedPreampDb(double value) =>
      _setMusicPreampDb(value, tagged: false);

  Future<void> _setMusicPreampDb(double value, {required bool tagged}) async {
    if (_disposed || !replayGainSupported) return;
    final preamp = clampMusicPreampDb(value);
    if (_output != null && _profile == _currentProfile()) {
      _outputGain = (
        mode: replayGainMode,
        taggedPreampDb: tagged ? preamp : musicTaggedPreampDb,
        untaggedPreampDb: tagged ? musicUntaggedPreampDb : preamp,
      );
      _notify();
    } else {
      await _saveReplayGain((preferences) => tagged
          ? preferences.setTaggedPreampDb(preamp)
          : preferences.setUntaggedPreampDb(preamp));
    }
  }

  Future<void> _saveReplayGain(
      Future<void> Function(MusicReplayGainPreferences) save) async {
    if (_disposed || !replayGainSupported) return;
    final database = db;
    final profile = database.profileId;
    await save(MusicReplayGainPreferences(database.forProfile(profile)));
    if (identical(db, database) && db.profileId == profile) {
      _notify();
    }
  }

  void attach(AudioPlayer player, {required String profileId}) =>
      attachBackend(_JustAudioEqualizer(player),
          owner: player,
          profileId: profileId,
          outputs: supported ? androidMusicOutputs : null);

  @visibleForTesting
  void attachBackend(MusicEqualizerBackend backend,
      {required Object owner,
      required String profileId,
      Stream<MusicOutput?>? outputs}) {
    if (_disposed) return;
    if (identical(owner, _owner) && _profile == profileId) return;
    final previous = _backend;
    final previousSession = _session;
    final hadEffect = _opened;
    _revision++;
    unawaited(_subscription?.cancel());
    if (_profile != profileId) {
      _profile = profileId;
      _desiredGains.clear();
      _enabled = false;
      _opened = false;
      _restoreOutput = _output != null;
      _loadOutputPreset();
    }
    _backend = backend;
    _owner = owner;
    _session = backend.sessionId;
    _parameters = null;
    _failed = false;
    _busy = false;
    if (hadEffect) unawaited(_disable(previous, previousSession));
    _subscription = backend.sessions.listen((session) {
      if (_disposed || !identical(_backend, backend) || session == _session) {
        return;
      }
      _revision++;
      _session = session;
      _parameters = null;
      _failed = false;
      _busy = false;
      _refresh();
    });
    if (supported && !identical(outputs, _outputSource)) {
      unawaited(_outputSubscription?.cancel());
      _outputSource = outputs;
      _outputSubscription = outputs?.listen(_outputChanged,
          onError: (Object _) => _outputChanged(null));
      _outputChanged(null);
    }
    _refresh();
  }

  void _outputChanged(MusicOutput? output) {
    if (_disposed || _profile != _currentProfile()) return;
    final previous = _output;
    _output = output;
    if (previous?.id == output?.id) {
      if (previous?.label != output?.label) _notify();
      return;
    }
    _loadOutputPreset();
    _restoreOutputEqualizer();
  }

  static _OutputGain? _gainFromPreset(MusicOutputPreset? preset) {
    final gain = preset?.gain;
    if (gain == null) return null;
    return (
      mode: gain.mode,
      taggedPreampDb: gain.preampDb,
      untaggedPreampDb: preset?.untaggedPreampDb ?? gain.preampDb,
    );
  }

  void _loadOutputPreset() {
    _outputSelection++;
    _savedOutputPreset = null;
    _outputGain = null;
    _outputPresetFailed = false;
    if (_output case final output?) {
      try {
        _savedOutputPreset = _outputPresets.read(_profile!, output.id);
        _outputGain = _gainFromPreset(_savedOutputPreset);
      } catch (_) {
        _outputPresetFailed = true;
      }
    }
  }

  void _restoreOutputEqualizer() {
    _revision++;
    _parameters = null;
    _busy = false;
    _failed = false;
    _restoreOutput = true;
    _refresh();
  }

  void _refresh() {
    if (!waiting &&
        (_opened || (_restoreOutput && _savedOutputPreset?.enabled != null))) {
      unawaited(_synchronize());
    } else {
      _notify();
    }
  }

  Future<void> detach(Object owner) async {
    if (!identical(owner, _owner)) return;
    await resetSession();
  }

  bool _current(int revision, MusicEqualizerBackend backend, int session) =>
      !_disposed &&
      revision == _revision &&
      identical(backend, _backend) &&
      _profile == _currentProfile() &&
      _session == session &&
      backend.sessionId == session;

  void _remember(MusicEqualizerParameters parameters) {
    _parameters = parameters;
    _desiredGains
      ..clear()
      ..addEntries(
          parameters.bands.map((band) => MapEntry(band.frequency, band.gain)));
  }

  Future<void> _run(
      Future<void> Function(MusicEqualizerBackend backend, int session,
              bool Function() current)
          action) async {
    final backend = _backend;
    final session = _session;
    if (_disposed ||
        !supported ||
        _busy ||
        backend == null ||
        session == null ||
        session <= 0 ||
        _profile != _currentProfile()) {
      return;
    }
    final revision = _revision;
    bool current() => _current(revision, backend, session);
    final previous = _operation;
    final done = Completer<void>();
    _operation = (backend: backend, session: session, done: done.future);
    _busy = true;
    _failed = false;
    _notify();
    try {
      // An output can change without replacing the Android audio session.
      // Finish old writes before applying to that same effect again.
      if (previous?.backend == backend && previous?.session == session) {
        await previous!.done;
        if (!current()) return;
      }
      await action(backend, session, current);
    } catch (_) {
      if (current()) {
        _failed = true;
        try {
          await backend
              .setEnabled(false, session)
              .timeout(const Duration(seconds: 2));
          if (current()) _enabled = false;
        } catch (_) {
          // Leave Disable available if the native effect could not be stopped.
        }
        // A multi-band operation can fail after one band succeeded. Display
        // only confirmed native values, never a successful-looking preset.
        try {
          final actual =
              await backend.read(session).timeout(const Duration(seconds: 2));
          if (current()) _remember(actual);
        } catch (_) {
          if (current()) _parameters = null;
        }
      }
    } finally {
      done.complete();
      if (_operation?.done == done.future) _operation = null;
      if (current()) {
        _busy = false;
        _notify();
      }
    }
  }

  Future<void> open() async {
    if (_disposed) return;
    _opened = true;
    await _synchronize();
  }

  Future<void> _synchronize() => _run((backend, session, current) async {
        var desiredGains = _desiredGains;
        var desiredEnabled = _enabled;
        if (_restoreOutput) {
          final preset = _savedOutputPreset;
          if (_opened) {
            await backend.setEnabled(false, session);
            if (!current()) return;
            _enabled = false;
          }
          _opened = true;
          desiredGains = preset?.gains ?? const {};
          desiredEnabled = preset?.enabled ?? false;
        }
        var parameters = await backend.read(session);
        if (!current()) return;
        for (final band in parameters.bands) {
          final desired = desiredGains[band.frequency] ?? 0.0;
          if (desired == band.gain) continue;
          await backend.setGain(band.index,
              desired.clamp(parameters.minimum, parameters.maximum), session);
          if (!current()) return;
        }
        await backend.setEnabled(desiredEnabled, session);
        if (!current()) return;
        _enabled = desiredEnabled;
        parameters = await backend.read(session);
        if (current()) {
          _remember(parameters);
          _restoreOutput = false;
        }
      });

  Future<void> saveOutputPreset() async {
    if (_output == null || !supported || _profile != _currentProfile()) return;
    final stored = _savedOutputPreset;
    await _writeOutputPreset(MusicOutputPreset(
        available ? _enabled : stored?.enabled,
        available ? _desiredGains : stored?.gains ?? const {},
        gain: (mode: replayGainMode, preampDb: musicTaggedPreampDb),
        untaggedPreampDb: musicUntaggedPreampDb));
  }

  Future<void> forgetOutputPreset() async {
    if (!hasOutputPreset) return;
    await _writeOutputPreset(null);
  }

  Future<void> _writeOutputPreset(MusicOutputPreset? preset) async {
    final output = _output;
    final profile = _profile;
    if (_disposed ||
        _busy ||
        savingOutputPreset ||
        profile == null ||
        profile != _currentProfile() ||
        output == null) {
      return;
    }
    bool current() =>
        !_disposed &&
        _profile == profile &&
        _currentProfile() == profile &&
        _output?.id == output.id;
    final selection = _outputSelection;
    _savingOutputPreset = true;
    _outputPresetFailed = false;
    _notify();
    try {
      await _outputPresets.write(profile, output.id, preset);
      if (current()) {
        _savedOutputPreset = preset;
        if (selection != _outputSelection) {
          _outputGain = _gainFromPreset(preset);
          _restoreOutputEqualizer();
        }
      }
    } catch (_) {
      if (current()) _outputPresetFailed = true;
    } finally {
      _savingOutputPreset = false;
      _notify();
    }
  }

  Future<void> setEnabled(bool enabled) =>
      _run((backend, session, current) async {
        await backend.setEnabled(enabled, session);
        if (current()) _enabled = enabled;
      });

  Future<void> setGain(int index, double gain) =>
      _run((backend, session, current) async {
        final parameters = _parameters;
        if (parameters == null ||
            !gain.isFinite ||
            !parameters.bands.any((band) => band.index == index)) {
          return;
        }
        await backend.setGain(
            index, gain.clamp(parameters.minimum, parameters.maximum), session);
        if (!current()) return;
        final actual = await backend.read(session);
        if (current()) _remember(actual);
      });

  Future<void> bass() => _preset((frequency) => frequency <= 250 ? 4 : 0);
  Future<void> treble() => _preset((frequency) => frequency >= 4000 ? 4 : 0);
  Future<void> flat() => _preset((_) => 0, enabled: false);

  Future<void> _preset(double Function(double) gain, {bool enabled = true}) =>
      _run((backend, session, current) async {
        final parameters = _parameters;
        if (parameters == null) return;
        for (final band in parameters.bands) {
          await backend.setGain(
              band.index,
              gain(band.frequency)
                  .clamp(parameters.minimum, parameters.maximum),
              session);
          if (!current()) return;
        }
        await backend.setEnabled(enabled, session);
        if (!current()) return;
        _enabled = enabled;
        final actual = await backend.read(session);
        if (current()) {
          _remember(actual);
          _restoreOutput = false;
        }
      });

  Future<void> _disable(MusicEqualizerBackend? backend, int? session) async {
    if (!supported || backend == null || session == null || session <= 0) {
      return;
    }
    try {
      await backend
          .setEnabled(false, session)
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Disposing a decoder also releases its effects. A stale session must
      // never be recreated just to clear an optional effect.
    }
  }

  Future<void> resetSession() async {
    final backend = _backend;
    final session = _session;
    final hadEffect = _opened;
    final subscription = _subscription;
    final outputSubscription = _outputSubscription;
    _revision++;
    _backend = null;
    _owner = null;
    _profile = null;
    _subscription = null;
    _outputSource = null;
    _outputSubscription = null;
    _output = null;
    _restoreOutput = false;
    _loadOutputPreset();
    _session = null;
    _parameters = null;
    _desiredGains.clear();
    _opened = false;
    _enabled = false;
    _busy = false;
    _failed = false;
    _notify();
    await subscription?.cancel();
    await outputSubscription?.cancel();
    if (hadEffect) await _disable(backend, session);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(resetSession());
    super.dispose();
  }
}
