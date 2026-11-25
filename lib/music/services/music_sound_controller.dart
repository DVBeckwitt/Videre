import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/replay_gain.dart';
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

/// Equalizer effects last for the current listening session and are created
/// only after Sound is opened. ReplayGain and preamp are profile preferences.
class MusicSoundController extends ChangeNotifier {
  MusicSoundController({
    bool? supported,
    String Function()? currentProfile,
  })  : supported = supported ??
            (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
        _currentProfile = currentProfile ?? (() => db.profileId);

  final bool supported;
  final String Function() _currentProfile;
  MusicEqualizerBackend? _backend;
  Object? _owner;
  String? _profile;
  StreamSubscription<int?>? _subscription;
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

  bool get replayGainSupported => supported;
  ReplayGainMode get replayGainMode =>
      replayGainSupported ? _replayGainPreferences.mode : ReplayGainMode.off;
  double get musicPreampDb =>
      replayGainSupported ? _replayGainPreferences.preampDb : 0;

  MusicReplayGainPreferences get _replayGainPreferences =>
      MusicReplayGainPreferences(db.forProfile(db.profileId));

  Future<void> setReplayGainMode(ReplayGainMode mode) =>
      _saveReplayGain((preferences) => preferences.setMode(mode));

  Future<void> setMusicPreampDb(double db) =>
      _saveReplayGain((preferences) => preferences.setPreampDb(db));

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
          owner: player, profileId: profileId);

  @visibleForTesting
  void attachBackend(MusicEqualizerBackend backend,
      {required Object owner, required String profileId}) {
    if (_disposed) return;
    if (identical(owner, _owner)) return;
    final previous = _backend;
    final previousSession = _session;
    final hadEffect = _opened;
    _revision++;
    unawaited(_subscription?.cancel());
    if (_profile != profileId) {
      _desiredGains.clear();
      _enabled = false;
      _opened = false;
    }
    _backend = backend;
    _owner = owner;
    _profile = profileId;
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
      _notify();
      if (_opened && !waiting) unawaited(open());
    });
    _notify();
    if (_opened && !waiting) unawaited(open());
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
    _busy = true;
    _failed = false;
    _notify();
    try {
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
      if (current()) {
        _busy = false;
        _notify();
      }
    }
  }

  Future<void> open() async {
    if (_disposed) return;
    _opened = true;
    await _run((backend, session, current) async {
      var parameters = await backend.read(session);
      if (!current()) return;
      for (final band in parameters.bands) {
        final desired = _desiredGains[band.frequency] ?? 0.0;
        if (desired == band.gain) continue;
        await backend.setGain(band.index,
            desired.clamp(parameters.minimum, parameters.maximum), session);
        if (!current()) return;
      }
      await backend.setEnabled(_enabled, session);
      if (!current()) return;
      parameters = await backend.read(session);
      if (current()) _remember(parameters);
    });
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
        if (current()) _remember(actual);
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
    _revision++;
    _backend = null;
    _owner = null;
    _profile = null;
    _subscription = null;
    _session = null;
    _parameters = null;
    _desiredGains.clear();
    _opened = false;
    _enabled = false;
    _busy = false;
    _failed = false;
    _notify();
    await subscription?.cancel();
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
