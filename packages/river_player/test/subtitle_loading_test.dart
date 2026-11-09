import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:river_player/river_player.dart';
import 'package:river_player/src/subtitles/better_player_subtitles_factory.dart';

const _validCaptions =
    'WEBVTT\n\n00:00:00.200 --> 00:00:05.000\nWorking captions\n\n';

Future<void> _respond(HttpRequest request,
    {String body = _validCaptions, int status = 200}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType('text', 'vtt');
  request.response.write(body);
  await request.response.close();
}

void main() {
  late HttpServer server;
  late Completer<HttpRequest> delayedRequest;
  late BetterPlayerController controller;
  late List<BetterPlayerEvent> events;
  String? receivedCookie;

  BetterPlayerSubtitlesSource source(String path) =>
      BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        name: path,
        urls: ['http://127.0.0.1:${server.port}/$path'],
        headers: {'Cookie': 'COMPANION_ID=7'},
      );

  setUp(() async {
    events = [];
    receivedCookie = null;
    controller = BetterPlayerController(
        BetterPlayerConfiguration(eventListener: events.add));
    delayedRequest = Completer<HttpRequest>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      receivedCookie = request.headers.value('Cookie');
      switch (request.uri.path) {
        case '/delayed':
          delayedRequest.complete(request);
        case '/empty':
          await _respond(request, body: '');
        case '/malformed':
          await _respond(request,
              body: 'WEBVTT\n\nbad --> worse\nBroken cue\n\n');
        case '/denied':
          await _respond(request, status: 403);
        default:
          await _respond(request);
      }
    });
  });

  tearDown(() async {
    controller.dispose();
    await server.close(force: true);
  });

  test('loads valid captions and forwards backend routing headers', () async {
    final selected = source('valid');
    await controller.setupSubtitleSource(selected);

    expect(receivedCookie, 'COMPANION_ID=7');
    expect(controller.betterPlayerSubtitlesSource, same(selected));
    expect(controller.subtitlesLines.single.texts, ['Working captions']);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.changedSubtitles);
  });

  test('loads a single SRT cue without a trailing blank line', () async {
    final selected = BetterPlayerSubtitlesSource(
      type: BetterPlayerSubtitlesSourceType.memory,
      content: '1\r\n00:00:00,000 --> 00:00:05,000\r\nWorking captions',
    );

    await controller.setupSubtitleSource(selected);

    expect(controller.betterPlayerSubtitlesSource, same(selected));
    expect(controller.subtitlesLines.single.start, Duration.zero);
    expect(controller.subtitlesLines.single.texts, ['Working captions']);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.changedSubtitles);
  });

  test('rejects non-success HTTP responses even if their body has cues',
      () async {
    await expectLater(
        BetterPlayerSubtitlesFactory.parseSubtitles(source('denied')),
        throwsA(isA<HttpException>()));
  });

  for (final failure in ['empty', 'denied', 'malformed']) {
    test('$failure captions report failure and preserve confirmed selection',
        () async {
      final working = source('valid');
      final failed = source(failure);
      await controller.setupSubtitleSource(working);
      events.clear();

      await controller.setupSubtitleSource(failed);

      expect(controller.betterPlayerSubtitlesSource, same(working));
      expect(controller.subtitlesLines.single.texts, ['Working captions']);
      expect(events.single.betterPlayerEventType,
          BetterPlayerEventType.subtitleLoadFailed);
      expect(events.single.parameters!['source'], same(failed));
    });
  }

  test('an initially empty remembered track is not marked selected', () async {
    await controller.setupSubtitleSource(source('empty'),
        sourceInitialize: true);

    expect(controller.betterPlayerSubtitlesSource, isNull);
    expect(controller.subtitlesLines, isEmpty);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.subtitleLoadFailed);
  });

  test('a failed track can be retried successfully', () async {
    final selected = source('delayed');
    final first = controller.setupSubtitleSource(selected);
    await _respond(await delayedRequest.future, body: '');
    await first;
    expect(controller.betterPlayerSubtitlesSource, isNull);

    delayedRequest = Completer<HttpRequest>();
    events.clear();
    final retry = controller.setupSubtitleSource(selected);
    await _respond(await delayedRequest.future);
    await retry;

    expect(controller.betterPlayerSubtitlesSource, same(selected));
    expect(controller.subtitlesLines.single.texts, ['Working captions']);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.changedSubtitles);
  });

  test('a stalled caption request reports a timeout', () async {
    await controller.setupSubtitleSource(source('delayed'));

    expect(controller.betterPlayerSubtitlesSource, isNull);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.subtitleLoadFailed);
    expect(events.single.parameters!['exception'], isA<TimeoutException>());
  });

  test('a late load cannot overwrite a newer subtitle selection', () async {
    final older = controller.setupSubtitleSource(source('delayed'));
    final request = await delayedRequest.future;
    final newer = source('valid');
    await controller.setupSubtitleSource(newer);
    await _respond(request);
    await older;

    expect(controller.betterPlayerSubtitlesSource, same(newer));
    expect(controller.subtitlesLines, hasLength(1));
    expect(events, hasLength(1));
  });

  test('turning subtitles off discards pending failures', () async {
    final loading = controller.setupSubtitleSource(source('delayed'));
    final request = await delayedRequest.future;
    final off =
        BetterPlayerSubtitlesSource(type: BetterPlayerSubtitlesSourceType.none);
    await controller.setupSubtitleSource(off);
    await _respond(request, body: '', status: 503);
    await loading;

    expect(controller.betterPlayerSubtitlesSource, same(off));
    expect(controller.subtitlesLines, isEmpty);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.changedSubtitles);
  });

  test('disposing the player discards pending loads', () async {
    final loading = controller.setupSubtitleSource(source('delayed'));
    final request = await delayedRequest.future;
    controller.dispose();
    await _respond(request);
    await loading;

    expect(controller.subtitlesLines, isEmpty);
    expect(events, isEmpty);
  });

  test('segmented tracks may be selected before their first cue arrives',
      () async {
    final segmented = BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        asmsIsSegmented: true,
        asmsSegments: []);
    await controller.setupSubtitleSource(segmented);

    expect(controller.betterPlayerSubtitlesSource, same(segmented));
    expect(controller.subtitlesLines, isEmpty);
    expect(events.single.betterPlayerEventType,
        BetterPlayerEventType.changedSubtitles);
  });
}
