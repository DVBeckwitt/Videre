import 'dart:async';

import 'package:flutter/services.dart';

typedef AndroidIncomingLink = ({String text, bool share, bool initial});
typedef AndroidIncomingContent = ({
  List<AndroidIncomingLink> links,
  Uri? audio
});

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

  static Stream<AndroidIncomingContent> events() {
    late final StreamController<AndroidIncomingContent> controller;
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
          final links = <AndroidIncomingLink>[];
          Uri? audio;
          for (final event in pending ?? const <Object?>[]) {
            if (event case {'audioUri': final String raw}) {
              final uri = Uri.tryParse(raw);
              if (uri != null &&
                  uri.scheme == 'content' &&
                  uri.authority.isNotEmpty &&
                  uri.path.isNotEmpty) {
                audio ??= uri;
              }
            } else if (event
                case {
                  'text': final String text,
                  'share': final bool share,
                  'initial': final bool initial,
                }) {
              links.add((text: text, share: share, initial: initial));
            }
          }
          if (links.isNotEmpty || audio != null) {
            controller.add((links: links, audio: audio));
          }
        } while (requested && !controller.isClosed);
      } catch (error, trace) {
        if (!controller.isClosed) controller.addError(error, trace);
      } finally {
        taking = false;
      }
    }

    controller = StreamController<AndroidIncomingContent>(
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
