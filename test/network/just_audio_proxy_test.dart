import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

class _DirectOverrides extends HttpOverrides {}

class _TrackingClient implements HttpClient {
  final Object? error;
  final HttpClient delegate = _DirectOverrides().createHttpClient(null);
  int closes = 0;
  final closed = Completer<void>();

  _TrackingClient(this.error);

  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    if (error != null) throw error!;
    return delegate.getUrl(uri);
  }

  @override
  void close({bool force = false}) {
    closes++;
    delegate.close(force: force);
    if (!closed.isCompleted) closed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TrackingOverrides extends HttpOverrides {
  final Object? error;
  final clients = <_TrackingClient>[];

  _TrackingOverrides(this.error);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _TrackingClient(error);
    clients.add(client);
    return client;
  }
}

class _FakeAudioPlatform extends JustAudioPlatform {
  final loaded = Completer<Uri>();
  _FakePlayer? player;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      player = _FakePlayer(request.id, loaded);

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
          DisposeAllPlayersRequest request) async =>
      DisposeAllPlayersResponse();

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await player?.events.close();
    return DisposePlayerResponse();
  }
}

class _FakePlayer extends AudioPlayerPlatform {
  final Completer<Uri> loaded;
  final events = StreamController<PlaybackEventMessage>.broadcast();

  _FakePlayer(super.id, this.loaded);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final playlist =
        request.audioSourceMessage as ConcatenatingAudioSourceMessage;
    loaded.complete(
        Uri.parse((playlist.children.single as UriAudioSourceMessage).uri));
    events.add(PlaybackEventMessage(
      processingState: ProcessingStateMessage.ready,
      updateTime: DateTime.now(),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(seconds: 1),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
    return LoadResponse(duration: const Duration(seconds: 1));
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();
  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();
  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
          SetShuffleOrderRequest request) async =>
      SetShuffleOrderResponse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling a partially forwarded audio body observes completion errors',
      () async {
    final oldPlatform = JustAudioPlatform.instance;
    final platform = _FakeAudioPlatform();
    JustAudioPlatform.instance = platform;
    final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final originClosed = Completer<void>();
    origin.listen((socket) {
      sockets.add(socket);
      var sent = false;
      socket.listen(
          (_) {
            if (sent) return;
            sent = true;
            socket.add(ascii.encode('HTTP/1.1 200 OK\r\n'
                'Content-Length: 217310\r\nConnection: close\r\n\r\n'));
            socket.add(List<int>.filled(8192, 42));
            // Keep the rest of the declared body pending, as with slow media.
            unawaited(socket.flush().catchError((Object _) {}));
          },
          onError: (Object _) {},
          onDone: () {
            if (!originClosed.isCompleted) originClosed.complete();
          });
    });
    final player = AudioPlayer(
      handleInterruptions: false,
      androidApplyAudioAttributes: false,
      handleAudioSessionActivation: false,
    );
    final localClient = _DirectOverrides().createHttpClient(null);
    final overrides = _TrackingOverrides(null);
    final uncaught = <Object>[];
    Object? downstreamError;
    try {
      await runZonedGuarded(() async {
        await HttpOverrides.runWithHttpOverrides(() async {
          await player.setAudioSource(AudioSource.uri(
            Uri.parse('http://127.0.0.1:${origin.port}/audio.webm'),
            headers: const {'X-Test': 'header proxy'},
          ));
          final localUri = await platform.loaded.future;
          final response = await (await localClient.getUrl(localUri)).close();
          expect(response.statusCode, HttpStatus.ok);
          final firstChunk = Completer<void>();
          final ended = Completer<void>();
          response.listen((chunk) {
            if (!firstChunk.isCompleted) firstChunk.complete();
          }, onError: (Object error) {
            downstreamError = error;
          }, onDone: () => ended.complete());
          await firstChunk.future.timeout(const Duration(seconds: 2));
          // Proxy policy changes forcibly close the underlying client while a
          // native player may still be reading the local forwarding response.
          overrides.clients.single.delegate.close(force: true);
          await ended.future.timeout(const Duration(seconds: 2));
          await originClosed.future.timeout(const Duration(seconds: 2));
          await overrides.clients.single.closed.future
              .timeout(const Duration(seconds: 2));
          await Future<void>.delayed(Duration.zero);
        }, overrides);
      }, (error, stack) => uncaught.add(error));
      expect(downstreamError, isA<HttpException>());
      expect(uncaught, isEmpty,
          reason:
              'A truncated local response must not detach a failing future.');
    } finally {
      localClient.close(force: true);
      await player.dispose();
      for (final socket in sockets) {
        socket.destroy();
      }
      await origin.close();
      JustAudioPlatform.instance = oldPlatform;
    }
  });

  for (final error in [
    const HttpException('Malformed upstream response'),
    const SocketException('Proxy unavailable'),
    null,
  ]) {
    test(
        'audio header proxy closes its client and never falls back after $error',
        () async {
      final oldPlatform = JustAudioPlatform.instance;
      final platform = _FakeAudioPlatform();
      JustAudioPlatform.instance = platform;
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final originSockets = <Socket>[];
      var originConnections = 0;
      origin.listen((socket) {
        originConnections++;
        originSockets.add(socket);
        socket.listen((_) {
          socket.add(ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\naudio'));
          socket.close();
        });
      });
      final player = AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
        handleAudioSessionActivation: false,
      );
      final localClient = _DirectOverrides().createHttpClient(null);
      final overrides = _TrackingOverrides(error);
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          await player.setAudioSource(AudioSource.uri(
            Uri.parse('http://127.0.0.1:${origin.port}/audio'),
            headers: const {'X-Test': 'header proxy'},
          ));
          final localUri = await platform.loaded.future;
          expect(localUri.port, isNot(origin.port));
          final response = await (await localClient.getUrl(localUri))
              .close()
              .timeout(const Duration(seconds: 2));
          expect(response.statusCode,
              error == null ? HttpStatus.ok : HttpStatus.badGateway);
          final body = await utf8.decodeStream(response);
          expect(body, error == null ? 'audio' : '');
          expect(originConnections, error == null ? 1 : 0);
          expect(overrides.clients, hasLength(1));
          await overrides.clients.single.closed.future
              .timeout(const Duration(seconds: 2));
          expect(overrides.clients.single.closes, 1);
        }, overrides);
      } finally {
        localClient.close(force: true);
        await player.dispose();
        for (final socket in originSockets) {
          socket.destroy();
        }
        await origin.close();
        JustAudioPlatform.instance = oldPlatform;
      }
    });
  }

  for (final sameOrigin in [false, true]) {
    test(
        'audio proxy scopes supplied headers on redirects and cached destinations ($sameOrigin)',
        () async {
      final oldPlatform = JustAudioPlatform.instance;
      final platform = _FakeAudioPlatform();
      JustAudioPlatform.instance = platform;
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final destination = sameOrigin
          ? origin
          : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final initialHeaders = <String?>[];
      final finalHeaders = <String?>[];
      final ranges = <String?>[];

      Future<void> finish(HttpRequest request) async {
        finalHeaders.add(request.headers.value('X-Instance-Key'));
        ranges.add(request.headers.value(HttpHeaders.rangeHeader));
        request.response.write('audio');
        await request.response.close();
      }

      origin.listen((request) async {
        if (request.uri.path == '/audio') {
          initialHeaders.add(request.headers.value('X-Instance-Key'));
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(HttpHeaders.locationHeader,
              'http://127.0.0.1:${destination.port}/final');
          await request.response.close();
        } else {
          await finish(request);
        }
      });
      if (!sameOrigin) destination.listen(finish);
      final player = AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
        handleAudioSessionActivation: false,
      );
      final localClient = _DirectOverrides().createHttpClient(null);
      final overrides = _TrackingOverrides(null);
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          await player.setAudioSource(AudioSource.uri(
            Uri.parse('http://127.0.0.1:${origin.port}/audio'),
            headers: const {'X-Instance-Key': 'instance-secret'},
          ));
          final localUri = await platform.loaded.future;
          for (var i = 0; i < 2; i++) {
            final request = await localClient.getUrl(localUri);
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-');
            final response =
                await request.close().timeout(const Duration(seconds: 2));
            expect(response.statusCode, HttpStatus.ok);
            expect(await utf8.decodeStream(response), 'audio');
          }
          expect(initialHeaders, ['instance-secret']);
          expect(
              finalHeaders,
              sameOrigin
                  ? ['instance-secret', 'instance-secret']
                  : [null, null]);
          expect(ranges, ['bytes=0-', 'bytes=0-']);
          expect(overrides.clients, hasLength(2));
          for (final client in overrides.clients) {
            await client.closed.future.timeout(const Duration(seconds: 2));
            expect(client.closes, 1);
          }
        }, overrides);
      } finally {
        localClient.close(force: true);
        await player.dispose();
        await origin.close(force: true);
        if (!sameOrigin) await destination.close(force: true);
        JustAudioPlatform.instance = oldPlatform;
      }
    });
  }
}
