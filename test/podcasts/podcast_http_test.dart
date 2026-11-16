import 'dart:async';
import 'dart:io';

import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/podcasts/services/podcast_feed_service.dart';
import 'package:clipious/podcasts/services/podcast_http.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _rss = '<rss><channel><title>Publisher</title><item><title>One</title>'
    '<enclosure url="https://cdn.example/one.mp3" type="audio/mpeg"/>'
    '</item></channel></rss>';

class _Client extends MockClient {
  bool closed = false;
  _Client(super.handler);
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'publisher fetch follows redirects without credentials and retains source URL',
      () async {
    final visited = <Uri>[];
    final client = _Client((request) async {
      visited.add(request.url);
      expect(request.followRedirects, isFalse);
      expect(
          request.headers.keys.map((name) => name.toLowerCase()),
          isNot(anyElement(
              anyOf('authorization', 'cookie', 'x-invidious-token'))));
      return request.url.host == 'publisher.example'
          ? http.Response('', 302,
              headers: {'location': 'https://cdn.example/feed.xml'})
          : http.Response(_rss, 200);
    });
    final feed = await PodcastFeedService(createClient: () => client)
        .fetch('https://publisher.example/feed.xml?private=token');
    expect(
        visited.map((uri) => uri.host), ['publisher.example', 'cdn.example']);
    expect(feed.feedUrl, 'https://publisher.example/feed.xml?private=token');
    expect(feed.episodes.single.title, 'One');
    expect(client.closed, isTrue);
  });

  test('blocked initial URL is rejected before client creation', () async {
    var created = false;
    final feeds = PodcastFeedService(createClient: () {
      created = true;
      return MockClient((_) async => http.Response(_rss, 200));
    });
    await expectLater(
        feeds.fetch('https://music.youtube.com/rss'), throwsFormatException);
    expect(created, isFalse);
  });

  for (final target in [
    'https://google.com/feed',
    'https://feeds.feedburner.com/feed',
    'https://user:private-token@cdn.example/feed',
    'file:///tmp/feed'
  ]) {
    test('blocked redirect is rejected before sending to $target', () async {
      var requests = 0;
      final client = _Client((_) async {
        requests++;
        return http.Response('', 302, headers: {'location': target});
      });
      await expectLater(
          PodcastFeedService(createClient: () => client)
              .fetch('https://publisher.example/feed'),
          throwsFormatException);
      expect(requests, 1);
      expect(client.closed, isTrue);
    });
  }

  test('redirect loop and non-success response fail with sanitized errors',
      () async {
    for (final status in [302, 404, 401]) {
      final client = _Client((_) async => http.Response('private-token', status,
          headers: {'location': 'https://publisher.example/feed'}));
      await expectLater(
          PodcastFeedService(createClient: () => client)
              .fetch('https://publisher.example/feed'),
          throwsA(isA<FormatException>().having((error) => error.toString(),
              'sanitized', isNot(contains('private-token')))));
      expect(client.closed, isTrue);
    }
  });

  test('transport failure and timeout omit private feed tokens', () async {
    final client = _Client((request) async =>
        throw http.ClientException('private-token', request.url));
    await expectLater(
        PodcastFeedService(createClient: () => client)
            .fetch('https://publisher.example/feed?token=private-token'),
        throwsA(isA<FormatException>().having((error) => error.toString(),
            'sanitized', isNot(contains('private-token')))));
    expect(client.closed, isTrue);
    final wait = Completer<http.Response>();
    final delayed = _Client((_) => wait.future);
    await expectLater(
        PodcastFeedService(
                createClient: () => delayed,
                timeout: const Duration(milliseconds: 10))
            .fetch('https://publisher.example/feed'),
        throwsFormatException);
    expect(delayed.closed, isTrue);
    wait.complete(http.Response('', 500));
  });

  test('oversized and invalid UTF-8 responses are rejected', () async {
    for (final response in [
      http.Response('x' * (podcastFeedMaximumBytes + 1), 200),
      http.Response.bytes([0xff, 0xfe], 200)
    ]) {
      final client = _Client((_) async => response);
      await expectLater(
          PodcastFeedService(createClient: () => client)
              .fetch('https://publisher.example/feed'),
          throwsFormatException);
      expect(client.closed, isTrue);
    }
  });

  test(
      'real publisher client blocks automatic redirects into Google and feedburner',
      () async {
    await NetworkProxy.instance.initialize(saved: '{}', configureNative: false);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var count = 0;
    server.listen((request) {
      count++;
      expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(request.headers.value(HttpHeaders.cookieHeader), isNull);
      request.response.statusCode = 302;
      request.response.headers.set(
          HttpHeaders.locationHeader,
          count == 1
              ? 'https://youtube.com/audio'
              : 'https://feeds.feedburner.com/audio');
      request.response.close();
    });
    final client = createPodcastHttpClient();
    addTearDown(() => client.close(force: true));
    for (var i = 0; i < 2; i++) {
      await expectLater(() async {
        final request = await client
            .getUrl(Uri.parse('http://127.0.0.1:${server.port}/audio'));
        await request.close();
      }, throwsFormatException);
    }
    expect(count, 2);
  });
}
