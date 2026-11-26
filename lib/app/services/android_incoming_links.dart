import 'dart:async';

import 'package:flutter/services.dart';

typedef AndroidIncomingContent = ({String? text, bool share, Uri? audio});

enum AndroidMusicShortcut { home, search, library, shuffleLocal }

/// Delivers Android intents held by the engine across activity attachment and
/// Dart startup. Notifications wake this reader. Taking the inbox consumes it.
class AndroidIncomingLinks {
  static const _channel = MethodChannel('videre/incoming_links');

  static AndroidMusicShortcut? musicShortcut(String action) => switch (action) {
        'com.github.dvbeckwitt.videre.action.MUSIC_HOME' =>
          AndroidMusicShortcut.home,
        'com.github.dvbeckwitt.videre.action.MUSIC_SEARCH' =>
          AndroidMusicShortcut.search,
        'com.github.dvbeckwitt.videre.action.MUSIC_LIBRARY' =>
          AndroidMusicShortcut.library,
        'com.github.dvbeckwitt.videre.action.MUSIC_SHUFFLE_LOCAL' =>
          AndroidMusicShortcut.shuffleLocal,
        _ => null,
      };

  static Stream<List<AndroidIncomingContent>> events() {
    late final StreamController<List<AndroidIncomingContent>> controller;
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
          final batch = <AndroidIncomingContent>[];
          for (final event in pending ?? const <Object?>[]) {
            if (event case {'audioUri': final String raw}) {
              final uri = Uri.tryParse(raw);
              if (uri != null &&
                  uri.scheme == 'content' &&
                  uri.authority.isNotEmpty &&
                  uri.path.isNotEmpty) {
                batch.add((text: null, share: false, audio: uri));
              }
            } else if (event
                case {
                  'text': final String text,
                  'share': final bool share,
                  'initial': bool _,
                }) {
              batch.add((text: text, share: share, audio: null));
            }
          }
          if (batch.isNotEmpty) controller.add(batch);
        } while (requested && !controller.isClosed);
      } catch (error, trace) {
        if (!controller.isClosed) controller.addError(error, trace);
      } finally {
        taking = false;
      }
    }

    controller = StreamController<List<AndroidIncomingContent>>(
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
