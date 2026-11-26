import 'dart:async';

import 'package:clipious/music/services/music_output_presets.dart';
import 'package:clipious/music/services/music_sound_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _Presets implements MusicOutputPresetStore {
  final values = <(String, String), MusicOutputPreset>{};

  @override
  MusicOutputPreset? read(String profileId, String outputId) =>
      values[(profileId, outputId)];

  @override
  Future<void> write(
      String profileId, String outputId, MusicOutputPreset? preset) async {
    if (preset == null) {
      values.remove((profileId, outputId));
    } else {
      values[(profileId, outputId)] = preset;
    }
  }
}

class _Backend implements MusicEqualizerBackend {
  final changes = StreamController<int?>.broadcast(sync: true);
  final calls = <({String operation, int session, int? band, double? gain})>[];
  final gains = <int, double>{0: 0, 1: 0, 2: 0};
  bool enabled = false;
  bool unavailable = false;
  int? failBandOnce;
  Completer<void>? pendingRead;
  Completer<void>? pendingGain;
  @override
  int? sessionId = 7;
  @override
  Stream<int?> get sessions => changes.stream;

  @override
  Future<MusicEqualizerParameters> read(int session) async {
    calls.add((operation: 'read', session: session, band: null, gain: null));
    final pending = pendingRead;
    pendingRead = null;
    if (pending != null) await pending.future;
    if (unavailable || session != sessionId) throw StateError('Unavailable');
    return MusicEqualizerParameters(-6, 6, [
      MusicEqualizerBand(0, 60, gains[0]!),
      MusicEqualizerBand(1, 1000, gains[1]!),
      MusicEqualizerBand(2, 8000, gains[2]!),
    ]);
  }

  @override
  Future<void> setEnabled(bool value, int session) async {
    calls.add((
      operation: value ? 'enable' : 'disable',
      session: session,
      band: null,
      gain: null
    ));
    if (session != sessionId) throw StateError('Stale session');
    enabled = value;
  }

  @override
  Future<void> setGain(int band, double gain, int session) async {
    calls.add((operation: 'gain', session: session, band: band, gain: gain));
    final pending = pendingGain;
    pendingGain = null;
    if (pending != null) await pending.future;
    if (session != sessionId) throw StateError('Stale session');
    if (failBandOnce == band) {
      failBandOnce = null;
      throw StateError('Native effect rejected this gain');
    }
    gains[band] = gain;
  }

  void replaceSession(int id) {
    sessionId = id;
    enabled = false;
    gains.updateAll((_, __) => 0);
    changes.add(id);
  }
}

Future<void> _settle(MusicSoundController controller) async {
  for (var i = 0; i < 50 && controller.busy; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(controller.busy, isFalse);
}

void main() {
  late MusicSoundController sound;
  late _Backend backend;
  late _Presets presets;
  late StreamController<MusicOutput?> outputs;
  late String profile;
  const speaker = MusicOutput('speaker', 'Speaker');
  const headphones = MusicOutput('headphones', 'Headphones');

  setUp(() {
    profile = 'person-a';
    presets = _Presets();
    outputs = StreamController<MusicOutput?>.broadcast(sync: true);
    sound = MusicSoundController(
        supported: true, currentProfile: () => profile, outputPresets: presets);
    backend = _Backend();
    sound.attachBackend(backend,
        owner: backend, profileId: profile, outputs: outputs.stream);
  });

  tearDown(() async {
    await sound.resetSession();
    sound.dispose();
    await backend.changes.close();
    await outputs.close();
  });

  test('saved outputs restore automatically and stay isolated by profile',
      () async {
    await presets.write(profile, speaker.id, MusicOutputPreset(true, {60: 4}));
    await presets.write(
        profile, headphones.id, MusicOutputPreset(true, {8000: 4}));
    outputs.add(speaker);
    await _settle(sound);
    expect(backend.gains, {0: 4, 1: 0, 2: 0});
    expect(backend.enabled, isTrue);
    expect(sound.hasOutputPreset, isTrue);

    outputs.add(headphones);
    await _settle(sound);
    expect(backend.gains, {0: 0, 1: 0, 2: 4});
    outputs.add(null);
    await _settle(sound);
    expect(backend.gains.values, everyElement(0));
    expect(backend.enabled, isFalse);
    await sound.setEnabled(true);
    await sound.saveOutputPreset();
    expect(presets.values.length, 2);

    outputs.add(speaker);
    await _settle(sound);
    expect(backend.gains[0], 4);
    backend.replaceSession(12);
    await _settle(sound);
    expect(backend.gains[0], 4);
    expect(backend.enabled, isTrue);

    await sound.resetSession();
    profile = 'person-b';
    sound.attachBackend(backend,
        owner: backend, profileId: profile, outputs: outputs.stream);
    outputs.add(speaker);
    await _settle(sound);
    expect(sound.hasOutputPreset, isFalse);
    expect(backend.enabled, isFalse);
  });

  test('a pending gain cannot overwrite the next output on the same session',
      () async {
    outputs.add(speaker);
    await _settle(sound);
    await sound.open();
    await sound.setEnabled(true);
    final pending = backend.pendingGain = Completer<void>();
    final old = sound.setGain(0, 6);
    outputs.add(headphones);
    expect(sound.parameters, isNull);
    expect(sound.busy, isTrue);

    pending.complete();
    await old;
    await _settle(sound);
    expect(backend.gains.values, everyElement(0));
    expect(backend.enabled, isFalse);
  });

  test('attaching playback does not allocate or enable an equalizer', () async {
    expect(backend.calls, isEmpty);
    backend.replaceSession(9);
    expect(backend.calls, isEmpty);
    await sound.open();
    expect(sound.available, isTrue);
    expect(sound.enabled, isFalse);
    expect(backend.enabled, isFalse);
    expect(backend.calls.where((call) => call.operation == 'gain'), isEmpty);
  });

  test('bass, treble and reset change confirmed native frequency bands',
      () async {
    await sound.open();
    await sound.bass();
    expect(backend.gains, {0: 4, 1: 0, 2: 0});
    expect(sound.parameters!.bands.first.gain, 4);
    expect(backend.enabled, isTrue);
    await sound.treble();
    expect(backend.gains, {0: 0, 1: 0, 2: 4});
    await sound.flat();
    expect(backend.gains.values, everyElement(0));
    expect(sound.enabled, isFalse);
    expect(backend.enabled, isFalse);
  });

  test('band changes are clamped and only confirmed native gains are exposed',
      () async {
    await sound.open();
    await sound.setGain(0, 40);
    expect(backend.gains[0], 6);
    expect(sound.parameters!.bands.first.gain, 6);
    final count = backend.calls.length;
    await sound.setGain(99, 2);
    await sound.setGain(0, double.nan);
    expect(backend.calls.length, count);
  });

  test('partial preset failure disables the effect and reports actual values',
      () async {
    await sound.open();
    backend.failBandOnce = 1;
    await sound.bass();
    expect(sound.failed, isTrue);
    expect(sound.enabled, isFalse);
    expect(backend.enabled, isFalse);
    expect(sound.parameters!.bands.first.gain, backend.gains[0]);
    await sound.flat();
    expect(sound.failed, isFalse);
    expect(backend.gains.values, everyElement(0));
  });

  test('unsupported hardware is an optional Sound failure', () async {
    backend.unavailable = true;
    await sound.open();
    expect(sound.failed, isTrue);
    expect(sound.available, isFalse);
    expect(sound.busy, isFalse);
    expect(backend.enabled, isFalse);
    backend.unavailable = false;
    await sound.open();
    expect(sound.available, isTrue);
  });

  test('same-profile native session replacement restores enabled gains',
      () async {
    await sound.open();
    await sound.bass();
    backend.replaceSession(13);
    await _settle(sound);
    expect(backend.gains, {0: 4, 1: 0, 2: 0});
    expect(backend.enabled, isTrue);
    expect(sound.available, isTrue);
  });

  test('late old-session read cannot overwrite a replacement session',
      () async {
    final gate = backend.pendingRead = Completer<void>();
    final old = sound.open();
    backend.replaceSession(19);
    await _settle(sound);
    final newCalls = backend.calls.length;
    gate.complete();
    await old;
    expect(backend.calls.length, newCalls);
    expect(sound.failed, isFalse);
    expect(sound.available, isTrue);
  });

  test('reset detaches and erases settings before another account binds',
      () async {
    await sound.open();
    await sound.bass();
    await sound.resetSession();
    expect(backend.enabled, isFalse);
    expect(sound.parameters, isNull);
    expect(sound.enabled, isFalse);
    profile = 'person-b';
    // Even if a platform reuses its session, the next person starts flat.
    final count = backend.calls.length;
    sound.attachBackend(backend, owner: backend, profileId: profile);
    expect(backend.calls.length, count);
    await sound.open();
    expect(backend.gains.values, everyElement(0));
    expect(backend.enabled, isFalse);
  });

  test('old-profile actions cannot reach a newly selected person', () async {
    await sound.open();
    final count = backend.calls.length;
    profile = 'person-b';
    await sound.bass();
    await sound.setEnabled(true);
    expect(backend.calls.length, count);
  });

  test('detaching an old decoder cannot clear a newer decoder', () async {
    final replacement = _Backend();
    addTearDown(replacement.changes.close);
    sound.attachBackend(replacement, owner: replacement, profileId: profile);
    await sound.open();
    await sound.bass();
    await sound.detach(backend);
    expect(sound.enabled, isTrue);
    expect(replacement.enabled, isTrue);
  });

  test('non-Android controls never call the native effect backend', () async {
    final unsupported =
        MusicSoundController(supported: false, currentProfile: () => profile);
    unsupported.attachBackend(backend, owner: backend, profileId: profile);
    await unsupported.open();
    await unsupported.bass();
    await unsupported.resetSession();
    expect(backend.calls, isEmpty);
    unsupported.dispose();
  });
}
