import 'dart:async';

import 'package:flutter/services.dart';

typedef AndroidIncomingLink = ({String text, bool share, bool initial});

/// Delivers Android intents held by the engine across activity attachment and
/// Dart startup. Notifications wake this reader. Taking the inbox consumes it.
class AndroidIncomingLinks {
  static const _channel = MethodChannel('videre/incoming_links');

  static Stream<List<AndroidIncomingLink>> events() {
    late final StreamController<List<AndroidIncomingLink>> controller;
    var taking = false;
    var requested = false;

    Future<void> takePending() async {
      requested = true;
      if (taking) return;
      taking = true;
      try {
        do {
          requested = false;
          final pending =
              await _channel.invokeListMethod<Object?>('takePending');
          if (controller.isClosed) return;
          final batch = <AndroidIncomingLink>[
            for (final event in pending ?? const <Object?>[])
              if (event
                  case {
                    'text': final String text,
                    'share': final bool share,
                    'initial': final bool initial,
                  })
                (text: text, share: share, initial: initial),
          ];
          if (batch.isNotEmpty) controller.add(batch);
        } while (requested && !controller.isClosed);
      } catch (error, trace) {
        if (!controller.isClosed) controller.addError(error, trace);
      } finally {
        taking = false;
      }
    }

    controller = StreamController<List<AndroidIncomingLink>>(
      onListen: () {
        _channel.setMethodCallHandler((call) async {
          if (call.method != 'linksAvailable') throw MissingPluginException();
          await takePending();
        });
        unawaited(takePending());
      },
      onCancel: () {
        _channel.setMethodCallHandler(null);
        unawaited(controller.close());
      },
    );
    return controller.stream;
  }
}
