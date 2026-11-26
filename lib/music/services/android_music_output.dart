import 'dart:async';

import 'package:flutter/services.dart';

class MusicOutput {
  const MusicOutput(this.id, this.label);

  final String id;
  final String label;
}

class MusicBluetoothOutputEvent {
  const MusicBluetoothOutputEvent.selected(this.outputId, {this.portId})
      : isDisconnect = false;
  const MusicBluetoothOutputEvent.disconnected(
    String this.outputId, {
    this.portId,
  }) : isDisconnect = true;

  final String? outputId;
  final int? portId;
  final bool isDisconnect;
}

final _androidOutput = _AndroidMusicOutput();

final androidMusicOutputs = _androidOutput.selections.map((event) {
  final id = event['id'];
  final label = event['label'];
  return id is String && id.isNotEmpty && label is String && label.isNotEmpty
      ? MusicOutput(id, label)
      : null;
});

final androidMusicBluetoothOutputs = Stream<MusicBluetoothOutputEvent>.multi((
  listener,
) {
  final current = _androidOutput.selection;
  if (current != null) {
    listener.add(_bluetoothSelection(current));
  }
  final subscription = _androidOutput.events.listen(
    (event) {
      switch (event['kind']) {
        case 'selected':
          listener.add(_bluetoothSelection(event));
        case 'bluetoothDisconnected':
          if (event['id'] case final String id when id.isNotEmpty) {
            listener.add(
              MusicBluetoothOutputEvent.disconnected(
                id,
                portId: _bluetoothPort(event),
              ),
            );
          }
      }
    },
    onError: listener.addError,
    onDone: listener.close,
  );
  listener.onCancel = subscription.cancel;
}, isBroadcast: true);

MusicBluetoothOutputEvent _bluetoothSelection(Map<Object?, Object?> event) {
  final id = event['bluetoothOutputId'];
  return MusicBluetoothOutputEvent.selected(
    id is String && id.isNotEmpty ? id : null,
    portId: _bluetoothPort(event),
  );
}

int? _bluetoothPort(Map<Object?, Object?> event) {
  final id = event['bluetoothPortId'];
  return id is int ? id : null;
}

/// The first device callback seeds the native baseline. Only later insertions
/// are forwarded, and a late subscriber never replays an insertion.
final androidWiredHeadsetInsertions =
    _wiredHeadsetPorts('wiredHeadsetInserted');

final androidWiredHeadsetRemovals = _wiredHeadsetPorts('wiredHeadsetRemoved');

Stream<int> _wiredHeadsetPorts(String kind) => _androidOutput.events
    .where((event) => event['kind'] == kind)
    .map((event) => event['id'])
    .where((id) => id is int)
    .cast<int>();

class _AndroidMusicOutput {
  final _platform = const EventChannel(
    'videre/music_output',
  ).receiveBroadcastStream();
  StreamSubscription<dynamic>? _subscription;
  Map<Object?, Object?>? selection;

  late final StreamController<Map<Object?, Object?>> _changes =
      StreamController<Map<Object?, Object?>>.broadcast(
    onListen: () {
      _subscription = _platform.listen((value) {
        if (value is! Map<Object?, Object?>) return;
        if (value['kind'] == 'selected') selection = value;
        _changes.add(value);
      }, onError: _changes.addError);
    },
    onCancel: () {
      selection = null;
      unawaited(_subscription?.cancel());
      _subscription = null;
    },
  );

  Stream<Map<Object?, Object?>> get events => _changes.stream;

  late final selections = Stream<Map<Object?, Object?>>.multi((listener) {
    final current = selection;
    if (current != null) listener.add(current);
    final subscription =
        events.where((event) => event['kind'] == 'selected').listen(
              listener.add,
              onError: listener.addError,
              onDone: listener.close,
            );
    listener.onCancel = subscription.cancel;
  }, isBroadcast: true);
}
