import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipious/globals.dart';
import 'package:clipious/network/content_link.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

class _DeferredLinkRequestService extends Service {
  _DeferredLinkRequestService(http.Client client) : super(httpClient: client);

  final requestReady = Completer<void>();
  final releaseRequest = Completer<void>();

  @override
  Future<ServerRequest> buildRequest(String baseUrl,
      {Map<String, String>? pathParams,
      Map<String, String?>? query,
      bool authenticated = false,
      String accept = 'application/json',
      bool forceJson = false,
      Server? serverOverride}) async {
    final request = await super.buildRequest(baseUrl,
        pathParams: pathParams,
        query: query,
        authenticated: authenticated,
        accept: accept,
        forceJson: forceJson,
        serverOverride: serverOverride);
    requestReady.complete();
    await releaseRequest.future;
    return request;
  }
}

void main() {
  test('cookie login still accepts a valid session response', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.bodyFields['email'], 'user');
      return http.Response('', 302,
          headers: {'set-cookie': 'SID=test-session; Secure; HttpOnly'});
    });
    addTearDown(client.close);
    expect(
        await Service(httpClient: client)
            .loginWithCookies('https://instance.example', 'user', 'password'),
        'SID=test-session');
  });

  test('failed cookie login does not disclose response cookies in logs',
      () async {
    final records = <LogRecord>[];
    final subscription = Logger('Service').onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final client = MockClient((_) async => http.Response('', 401,
        headers: {'set-cookie': 'SID=private-session-value; HttpOnly'}));
    addTearDown(client.close);
    final api = Service(httpClient: client);

    await expectLater(
        api.loginWithCookies('https://instance.example', 'user', 'password'),
        throwsA(isA<InvidiousServiceError>()));
    expect(records.map((record) => '${record.message} ${record.error}').join(),
        isNot(contains('private-session-value')));
  });

  group('incoming content resolution', () {
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      await db.upsertServer(const Server(url: 'https://inv.example'));
    });
    tearDown(() => db.close());

    test('keeps the captured account and does not log the source address',
        () async {
      final records = <LogRecord>[];
      final subscription = Logger('Service').onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      const captured = Server(
        url: 'https://private-instance.example/iv',
        id: 'source-account',
        authToken: 'captured-account-token',
        customHeaders: {'Cookie': 'COMPANION_ID=7'},
      );
      final original = ContentLink.parseAddress(
          'https://www.youtube.com/@private-handle?si=private-tracking')!;
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        const replacement = Server(url: 'https://new-selection.example');
        await db.upsertServer(replacement);
        await db.useServer(replacement);
        return http.Response(
            '{"browseId":"UC_kRDKYrUlrbtrSiyu5Tflg","pageType":"WEB_PAGE_TYPE_CHANNEL"}',
            200,
            request: request,
            headers: {'content-type': 'application/json'});
      });
      addTearDown(client.close);

      final result = await Service(httpClient: client)
          .resolveContentLink(original, server: captured);

      expect(result?.kind, ContentLinkKind.channel);
      expect(result?.id, 'UC_kRDKYrUlrbtrSiyu5Tflg');
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.url.origin, 'https://private-instance.example');
      expect(request.url.path, '/iv/api/v1/resolveurl');
      expect(request.url.queryParameters['url'],
          'https://www.youtube.com/@private-handle');
      expect(request.url.queryParameters['local'], 'true');
      expect(request.followRedirects, isFalse);
      expect(request.headers['Authorization'], 'Bearer captured-account-token');
      expect(request.headers['Cookie'], 'COMPANION_ID=7');
      expect(request.headers[gatewayContextHeader],
          captured.headersForUrl(captured.url)![gatewayContextHeader]);
      final logText =
          records.map((record) => '${record.message} ${record.error}').join();
      expect(logText, isNot(contains('private-handle')));
      expect(logText, isNot(contains('private-tracking')));
      expect(logText, isNot(contains('captured-account-token')));
    });

    test('keeps a resolved Music playlist in the music domain', () async {
      final original = ContentLink.parseAddress(
          'https://music.youtube.com/browse/MPREb_K8qWMWVqXGi')!;
      final client = MockClient((request) async {
        expect(request.url.host, 'inv.example');
        return http.Response(
            '{"playlistId":"PLresolved_playlist","pageType":"WEB_PAGE_TYPE_PLAYLIST"}',
            200);
      });
      addTearDown(client.close);

      final result = await Service(httpClient: client).resolveContentLink(
          original,
          server: await db.getCurrentlySelectedServer());

      expect(result?.kind, ContentLinkKind.playlist);
      expect(result?.id, 'PLresolved_playlist');
      expect(result?.music, isTrue);
    });

    for (final fixture in [
      (status: 200, body: '{"browseId":"not-a-channel"}'),
      (status: 200, body: '{"videoId":"../private"}'),
      (status: 200, body: '{"url":"https://youtube.com/watch?v=dQw4w9WgXcQ"}'),
      (status: 200, body: '[]'),
      (status: 200, body: '<html>private upstream detail</html>'),
      (status: 401, body: '{"error":"private upstream detail"}'),
      (status: 429, body: '{"error":"private upstream detail"}'),
      (status: 500, body: '{"error":"private upstream detail"}'),
      (status: 302, body: ''),
    ]) {
      test(
          'rejects unsupported resolver response ${fixture.status} ${fixture.body}',
          () async {
        final records = <LogRecord>[];
        final subscription = Logger('Service').onRecord.listen(records.add);
        addTearDown(subscription.cancel);
        final original =
            ContentLink.parseAddress('https://youtube.com/@private-handle')!;
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          expect(request.url.host, 'inv.example');
          expect(request.followRedirects, isFalse);
          return http.Response(fixture.body, fixture.status,
              request: request,
              headers: {'location': 'https://youtube.com/@private-handle'});
        });
        addTearDown(client.close);

        expect(
            await Service(httpClient: client).resolveContentLink(original,
                server: await db.getCurrentlySelectedServer()),
            isNull);
        expect(calls, 1);
        final logText =
            records.map((record) => '${record.message} ${record.error}').join();
        expect(logText, isNot(contains('private-handle')));
        expect(logText, isNot(contains('private upstream detail')));
      });
    }

    test('does not resolve known IDs or use an official destination instance',
        () async {
      final client = MockClient((_) async {
        fail('This input must not cause a network request');
      });
      addTearDown(client.close);
      final api = Service(httpClient: client);
      expect(
          await api.resolveContentLink(
              ContentLink.parseAddress('https://youtu.be/dQw4w9WgXcQ')!,
              server: await db.getCurrentlySelectedServer()),
          isNull);
      expect(
          await api.resolveContentLink(
              ContentLink.parseAddress('https://youtube.com/@example')!,
              server: const Server(url: 'https://www.youtube.com')),
          isNull);
    });

    for (final changeProxy in [false, true]) {
      test(
          'does not dispatch a prepared resolver request after ${changeProxy ? 'proxy change' : 'newer navigation'}',
          () async {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          return http.Response('{"videoId":"dQw4w9WgXcQ"}', 200);
        });
        addTearDown(client.close);
        final api = _DeferredLinkRequestService(client);
        var current = true;
        final pending = api.resolveContentLink(
            ContentLink.parseAddress('https://youtube.com/@example')!,
            server: await db.getCurrentlySelectedServer(),
            isCurrent: () => current);
        await api.requestReady.future;
        if (changeProxy) {
          await NetworkProxy.instance
              .initialize(saved: '{}', configureNative: false);
        } else {
          current = false;
        }
        api.releaseRequest.complete();

        expect(await pending, isNull);
        expect(calls, 0);
      });
    }

    test('discards a resolver response after the proxy configuration changes',
        () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final client = MockClient((_) {
        started.complete();
        return response.future;
      });
      addTearDown(client.close);
      final pending = Service(httpClient: client).resolveContentLink(
          ContentLink.parseAddress('https://youtube.com/@example')!,
          server: await db.getCurrentlySelectedServer());
      await started.future;
      await NetworkProxy.instance
          .initialize(saved: '{}', configureNative: false);
      response.complete(http.Response('{"videoId":"dQw4w9WgXcQ"}', 200));

      expect(await pending, isNull);
    });
  });

  group('history synchronization', () {
    test('awaits memberships without manufacturing completed playback',
        () async {
      final database = await SembastSqfDb.createInMemory();
      db = database;
      await database.upsertServer(const Server(
          url: 'https://instance.example', authToken: 'test-history-token'));
      await database.saveProgress(Progress(0.4, 'partial'));
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/auth/history');
        expect(request.headers['Authorization'], 'Bearer test-history-token');
        return http.Response('["first","partial","second"]', 200);
      });
      addTearDown(() async {
        client.close();
        await database.close();
      });
      await Service(httpClient: client).syncHistory();
      expect(database.getVideoProgress('partial'), 0.4);
      expect(database.getVideoProgress('first'), 0);
      expect(WatchRepository(database).isWatched('first'), isTrue);
      expect(WatchRepository(database).isWatched('partial'), isFalse);
      expect(WatchRepository(database).isWatched('second'), isTrue);
    });

    test('failed server pulls preserve local positions and pending intent',
        () async {
      final database = await SembastSqfDb.createInMemory();
      db = database;
      const account =
          Server(url: 'https://instance.example', authToken: 'token');
      await database.upsertServer(account);
      await database.saveProgress(Progress(0.4, 'partial'));
      final repository = WatchRepository(database);
      await repository.mark('pending', true, account: account);
      final client = MockClient((_) async => http.Response('Unavailable', 503));
      addTearDown(() async {
        client.close();
        await database.close();
      });
      await Service(httpClient: client).syncHistory();
      expect(database.getVideoProgress('partial'), 0.4);
      expect(repository.pending(account.accountId), hasLength(1));
      expect(repository.syncStatus(account.accountId)?['state'], 'pending');
    });
  });

  test('the votes request parses valid like estimates independently', () async {
    db = await SembastSqfDb.createInMemory();
    Map<String, Object?> payload = {};
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      return http.Response(jsonEncode(payload), 200);
    });
    addTearDown(() async {
      client.close();
      await db.close();
    });
    final service = Service(httpClient: client);

    const cases = <(Map<String, Object?>, int?, int?)>[
      ({'dislikes': 71}, null, 71),
      ({'likes': null, 'dislikes': 71}, null, 71),
      ({'likes': -1, 'dislikes': 71}, null, 71),
      ({'likes': 10.5, 'dislikes': 71}, null, 71),
      ({'likes': '10', 'dislikes': 71}, null, 71),
      ({'likes': true, 'dislikes': 71}, null, 71),
      ({'likes': 0, 'dislikes': 71}, 0, 71),
      ({'likes': 123, 'dislikes': 0}, 123, 0),
      ({'likes': 123}, 123, null),
      ({'likes': 123, 'dislikes': 'unknown'}, 123, null),
    ];
    for (final (data, expectedLikes, expectedDislikes) in cases) {
      payload = data;
      final votes = await service.getDislikes('video-id');
      expect(votes.likes, expectedLikes, reason: '$data');
      expect(votes.dislikes, expectedDislikes, reason: '$data');
    }
    expect(
        requests,
        List.filled(
            cases.length,
            Uri.parse(
                'https://returnyoutubedislikeapi.com/votes?videoId=video-id')));

    await db.saveSetting(SettingsValue(
        returnYoutubeDislikeUrlSettingName, 'https://votes.example/custom/'));
    payload = {'likes': 123, 'dislikes': 71};
    final customVotes = await service.getDislikes('video-id');
    expect(customVotes.likes, 123);
    expect(customVotes.dislikes, 71);
    expect(requests.last,
        Uri.parse('https://votes.example/custom/votes?videoId=video-id'));
    expect(requests, hasLength(cases.length + 1));
  });

  test('a stalled dislike request times out', () async {
    db = await SembastSqfDb.createInMemory();
    final client = MockClient((_) => Completer<http.Response>().future);
    addTearDown(() async {
      client.close();
      await db.close();
    });

    await expectLater(Service(httpClient: client).getDislikes('video-id'),
        throwsA(isA<TimeoutException>()));
  }, timeout: const Timeout(Duration(seconds: 5)));

  group('Invidious endpoint compatibility', () {
    test('keeps the current video and authenticated subscription endpoints',
        () {
      expect(urlGetVideo, '/api/v1/videos/:id');
      expect(urlGetUserFeed, '/api/v1/auth/feed');
      expect(urlGetSubscriptions, '/api/v1/auth/subscriptions');
      expect(urlGetTranscript, '/api/v1/transcripts/:id');
      expect(urlGetCaptions, '/api/v1/captions/:id');
    });
  });

  group('Service request encoding', () {
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      await db.upsertServer(const Server(url: 'https://inv.example'));
    });

    tearDown(() => db.close());

    test('all requests proxy media even with a legacy direct-playback setting',
        () async {
      final api = Service();
      addTearDown(api.httpClient.close);
      for (final value in [null, 'true', '', 'invalid', 'FALSE', 'false']) {
        if (value != null) {
          await db.saveSetting(SettingsValue(useProxySettingName, value));
        }
        final request = await api.buildRequest('/api/v1/videos/example');
        expect(request.uri.queryParameters['local'], 'true',
            reason: 'stored preference: $value');
      }
    });

    test('continuations survive every paginated endpoint unchanged', () async {
      const continuation = 'next+page/==&cursor=%2B#fragment';
      final paths = <String>[];
      final client = MockClient((request) async {
        paths.add(request.url.path);
        expect(request.url.queryParameters['continuation'], continuation);
        expect(request.url.queryParameters, isNot(contains('cursor')));
        expect(request.url.hasFragment, isFalse);
        return http.Response('{"videos":[],"playlists":[],"comments":[]}', 200);
      });
      addTearDown(client.close);
      final api = Service(httpClient: client);

      await api.getComments('video-id', continuation: continuation);
      await api.getChannelVideos('channel-id', continuation);
      await api.getChannelStreams('channel-id', continuation);
      await api.getChannelShorts('channel-id', continuation);
      await api.getChannelPlaylists('channel-id', continuation: continuation);

      expect(paths, hasLength(5));
    });

    test('search and suggestions encode query text exactly once', () async {
      const query = 'C++ & 50% #music / caf\u00e9';
      final client = MockClient((request) async {
        expect(request.url.queryParameters['q'], query);
        return http.Response(
            request.url.path == urlSearch
                ? '[]'
                : jsonEncode({'query': query, 'suggestions': <String>[]}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
      addTearDown(client.close);
      final api = Service(httpClient: client);

      await api.search(query);
      await api.getSearchSuggestion(query);
    });

    test('proxy parameter leaves caller queries untouched', () async {
      await db.saveSetting(SettingsValue(useProxySettingName, 'true'));
      const query = {'continuation': 'next+page', 'omitted': null};
      final request = await Service().buildRequest(
          '/api/v1/comments/video-id?source=youtube',
          query: query);

      expect(request.uri.queryParameters, {
        'source': 'youtube',
        'continuation': 'next+page',
        'local': 'true',
      });
      expect(query, {'continuation': 'next+page', 'omitted': null});
    });

    test('suggestions decode entities without treating text as markup',
        () async {
      final client = MockClient((_) async => http.Response(
          jsonEncode({
            'query': 'test',
            'suggestions': [
              'it&#x27;s &#39;quoted&#39; &amp; named',
              'music &#x1F3B5;',
              '<b>literal</b> &lt;tag&gt;',
              'plain  text; &#oops; &#;',
              'bad codepoint: &#1114112;',
            ]
          }),
          200));
      addTearDown(client.close);

      final result =
          await Service(httpClient: client).getSearchSuggestion('test');

      expect(result.suggestions, [
        "it's 'quoted' & named",
        'music \u{1F3B5}',
        '<b>literal</b> <tag>',
        'plain  text; &#oops; &#;',
        'bad codepoint: \uFFFD',
      ]);
    });
  });

  group('Service.handleResponse', () {
    final service = Service();

    test('reports an HTML reverse-proxy response before JSON decoding', () {
      final response = http.Response(
        '<a href="https://auth.example/login">Sign in</a>',
        302,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.message,
            'message',
            'The reverse proxy returned HTML instead of Invidious JSON',
          ),
        ),
      );
    });

    test('reports a successful HTML proxy login page as a proxy error', () {
      final response = http.Response(
        '<!doctype html><title>Sign in</title>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>()
              .having(
                (error) => error.message,
                'message',
                'The reverse proxy returned HTML instead of Invidious JSON',
              )
              .having(
                (error) => error.responseWasHtml,
                'responseWasHtml',
                isTrue,
              ),
        ),
      );
    });

    test('reports malformed JSON returned with a successful status', () {
      final response = http.Response(
        '{not-json',
        200,
        headers: {'content-type': 'application/json'},
      );

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.message,
            'message',
            'The server returned malformed JSON',
          ),
        ),
      );
    });

    test('reports a non-JSON HTTP error with its status', () {
      final response = http.Response('Unavailable', 503);

      expect(
        () => service.handleResponse(response),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.message,
            'message',
            'Request failed with HTTP 503',
          ),
        ),
      );
    });

    test('accepts an empty successful response', () {
      expect(service.handleResponse(http.Response('', 204)), isNull);
    });
  });

  group('Service.getTranscript', () {
    final caption = Caption(
      'English (auto-generated) & commentary',
      'en',
      '/api/v1/captions/video-id?label=English',
    );

    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      const server = Server(
        url: 'https://inv.example',
        customHeaders: {'Authorization': 'Basic private-instance'},
      );
      await db.upsertServer(server);
      await db.useServer(server);
    });

    tearDown(() async {
      service = Service();
      await db.close();
    });

    test('returns the structured transcript without requesting captions',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          '''{"transcript":{"languageCode":"en","autoGenerated":true,"label":"English (auto-generated) & commentary","body":[{"type":"regular","startMs":0.0,"endMs":1500.0,"line":"Transcript text"}]}}''',
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final transcript =
          await Service(httpClient: client).getTranscript('video-id', caption);

      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/v1/transcripts/video-id');
      expect(
        requests.single.url.queryParameters['label'],
        caption.label,
      );
      expect(
        requests.single.headers['Authorization'],
        'Basic private-instance',
      );
      expect(transcript, isA<VideoTranscript>());
      expect(transcript.lines.single.text, 'Transcript text');
      expect(transcript.label, caption.label);
      expect(transcript.languageCode, 'en');
      expect(transcript.autoGenerated, isTrue);
    });

    test('falls back to WebVTT with the same label and custom headers',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.startsWith('/api/v1/transcripts/')) {
          return http.Response(
            '{"error":"Not found"}',
            404,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          'WEBVTT\n\n00:01.000 --> 00:02.000\nFallback text\n',
          200,
          headers: {'content-type': 'text/vtt; charset=utf-8'},
        );
      });

      final transcript =
          await Service(httpClient: client).getTranscript('video-id', caption);

      expect(requests, hasLength(2));
      expect(requests[0].url.path, '/api/v1/transcripts/video-id');
      expect(requests[1].url.path, '/api/v1/captions/video-id');
      for (final request in requests) {
        expect(request.url.queryParameters['label'], caption.label);
        expect(request.headers['Authorization'], 'Basic private-instance');
      }
      expect(transcript.lines.single.text, 'Fallback text');
    });

    for (final track in [
      '/api/v1/captions/video-id?label=English&check=private%2Bsigned',
      '/companion/api/v1/captions/video-id?label=English&check=private%2Bsigned',
      '/api/v1/captions/video-id?label=English&lang=en&tlang=en&check=private%2Bsigned',
    ]) {
      test('direct transcript preserves a matching signed caption track $track',
          () async {
        final requests = <http.Request>[];
        final records = <LogRecord>[];
        final subscription = Logger('Service').onRecord.listen(records.add);
        addTearDown(subscription.cancel);
        final client = MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) return http.Response('', 500);
          expect(request.url.path, Uri.parse(track).path);
          expect(request.url.query, Uri.parse(track).query);
          return http.Response(
              'WEBVTT\n\n00:01.000 --> 00:02.000\nSigned caption\n\n'
              '00:03.000 --> 00:04.000\nSigned caption\n\n',
              200,
              headers: {'content-type': 'text/vtt'});
        });
        addTearDown(client.close);

        final transcript = await Service(httpClient: client)
            .getTranscript('video-id', Caption('English', 'en', track));

        expect(requests, hasLength(2));
        expect(requests.last.followRedirects, isFalse);
        expect(
            requests.last.headers['Authorization'], 'Basic private-instance');
        expect(transcript.label, 'English');
        expect(transcript.languageCode, 'en');
        expect(transcript.lines.single.text, 'Signed caption');
        expect(
            records.map((record) => '${record.message} ${record.error}').join(),
            isNot(contains('private%2Bsigned')));
      });
    }

    for (final track in [
      '/api/v1/captions/video-id?label=German&check=private',
      '/api/v1/captions/video-id?check=private',
      '/api/v1/captions/another-video?label=English&check=private',
      '/login?label=English&check=private',
      '/api/v1/captions/video-id?label=English&lang=de&check=private',
      '/api/v1/captions/video-id?label=English&tlang=de&check=private',
      '/api/v1/captions/video-id?label=English&label=German&check=private',
      '/api/v1/captions/video-id?label=English&lang=en&lang=de&check=private',
      'https://youtube.com/api/v1/captions/video-id?label=English&check=private',
    ]) {
      test(
          'direct transcript retains canonical track for mismatched advertisement $track',
          () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) return http.Response('', 500);
          return http.Response(
              'WEBVTT\n\n00:01.000 --> 00:02.000\nCanonical caption\n\n', 200,
              headers: {'content-type': 'text/vtt'});
        });
        addTearDown(client.close);

        final transcript = await Service(httpClient: client)
            .getTranscript('video-id', Caption('English', 'en', track));

        expect(requests, hasLength(2));
        expect(requests.last.url.origin, 'https://inv.example');
        expect(requests.last.url.path, '/api/v1/captions/video-id');
        expect(requests.last.url.queryParameters['label'], 'English');
        expect(requests.last.url.queryParameters.containsKey('check'), isFalse);
        expect(transcript.lines.single.text, 'Canonical caption');
      });
    }

    test('throws an Invidious error when all instance transcript routes fail',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response('Unavailable', 503);
      });

      await expectLater(
        Service(httpClient: client).getTranscript('video-id', caption),
        throwsA(isA<InvidiousServiceError>()),
      );

      expect(requests, hasLength(3));
      expect(
        requests.every((request) => request.url.host == 'inv.example'),
        isTrue,
      );
    });

    test(
        'direct transcript uses the captured NerdVPN watch track once and deduplicates',
        () async {
      final requests = <http.Request>[];
      const server = Server(
          url: 'https://invidious.nerdvpn.de',
          id: 'transcript-account',
          customHeaders: {'Cookie': 'COMPANION_ID=7'});
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.startsWith('/api/v1/transcripts/')) {
          const replacement = Server(url: 'https://new-selection.example');
          await db.upsertServer(replacement);
          await db.useServer(replacement);
          return http.Response('{"error":"Transcript unavailable"}', 500);
        }
        if (request.url.path == '/api/v1/captions/video-id') {
          return http.Response('WEBVTT\n\nKind: captions\n', 200,
              headers: {'content-type': 'text/vtt'});
        }
        if (request.url.path == '/watch') {
          return http.Response(
              '''<video id="player"><track kind="captions"
              label="English" src="/companion/api/v1/captions/video-id?label=English&amp;check=private%2Bsigned"></video>''',
              200,
              headers: {'content-type': 'text/html'});
        }
        expect(request.url.query, 'label=English&check=private%2Bsigned');
        return http.Response(
            'WEBVTT\n\n00:01.000 --> 00:02.000\nRepeated\n\n'
            '00:03.000 --> 00:04.000\nRepeated\n\n'
            '00:05.000 --> 00:06.000\nNext line\n\n',
            200,
            headers: {'content-type': 'text/vtt'});
      });
      addTearDown(client.close);

      final transcript = await Service(httpClient: client).getTranscript(
          'video-id', Caption('English', 'en', '/api/v1/captions/video-id'),
          serverOverride: server);

      expect(requests.map((request) => request.url.path), [
        '/api/v1/transcripts/video-id',
        '/api/v1/captions/video-id',
        '/watch',
        '/companion/api/v1/captions/video-id'
      ]);
      expect(transcript.label, 'English');
      expect(transcript.languageCode, 'en');
      expect(
          transcript.lines.map((line) => line.text), ['Repeated', 'Next line']);
      expect(transcript.lines.first.startMs, 1000);
      for (final request in requests) {
        expect(request.url.origin, server.url);
        expect(request.followRedirects, isFalse);
        expect(request.headers['Cookie'], 'COMPANION_ID=7');
        expect(request.headers[gatewayContextHeader],
            server.headersForUrl(server.url)![gatewayContextHeader]);
      }
    });

    for (final refusedAt in [1, 2]) {
      for (final status in [401, 403, 429, 503]) {
        test(
            'direct transcript HTTP $status at request $refusedAt stops fallback',
            () async {
          var calls = 0;
          final client = MockClient((_) async => ++calls == refusedAt
              ? http.Response.bytes([0xff], status,
                  headers: {'retry-after': '60'})
              : http.Response('', 500));
          addTearDown(client.close);
          await expectLater(
              Service(httpClient: client).getTranscript('video-id', caption),
              throwsA(isA<InvidiousServiceError>()
                  .having((error) => error.statusCode, 'status', status)));
          expect(calls, refusedAt);
        });
      }
      for (final failure in [
        const NerdVpnAccessRequired('waiting'),
        const GatewayAuthenticationRequired(),
        const GatewayTransportUnavailable(),
        const HandshakeException('Certificate rejected'),
        const SocketException('Request cancelled'),
        StateError('HttpClient is closed'),
      ]) {
        test(
            'direct transcript ${failure.runtimeType} at request $refusedAt stops fallback',
            () async {
          var calls = 0;
          final client = MockClient((_) async {
            if (++calls == refusedAt) throw failure;
            return http.Response('', 500);
          });
          addTearDown(client.close);
          await expectLater(
              Service(httpClient: client).getTranscript('video-id', caption),
              throwsA(same(failure)));
          expect(calls, refusedAt);
        });
      }
    }

    test('direct transcript never follows an off-origin watch caption track',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return request.url.path == '/watch'
            ? http.Response(
                '''<video id="player"><track kind="captions" label="English"
                src="https://youtube.com/api/v1/captions/video-id"></video>''',
                200)
            : http.Response('', 500);
      });
      addTearDown(client.close);
      await expectLater(
          Service(httpClient: client).getTranscript('video-id',
              Caption('English', 'en', '/api/v1/captions/video-id')),
          throwsA(isA<InvidiousServiceError>()));
      expect(requests, hasLength(3));
      expect(requests.every((request) => request.url.host == 'inv.example'),
          isTrue);
    });

    for (final origin in [
      'https://invidious.nerdvpn.de',
      'https://invidious.dvbeckwitt.duckdns.org',
    ]) {
      for (final generated in [false, true]) {
        test(
            'playback captions use the video account on $origin (auto=$generated)',
            () async {
          final requests = <http.Request>[];
          final server = Server(
            url: origin,
            id: 'playing-account',
            customHeaders: {'Cookie': 'COMPANION_ID=7'},
          );
          final selectedCaption = Caption(
            generated ? 'English (auto-generated)' : 'English',
            'en',
            '/api/v1/captions/playing-video?label=English',
          );
          final client = MockClient((request) async {
            requests.add(request);
            if (request.url.path.startsWith('/api/v1/captions/')) {
              // The affected instances advertise a valid caption URL but the
              // legacy timedtext endpoint returns a successful, empty body.
              return http.Response('', 200,
                  headers: {'content-type': 'text/vtt'});
            }
            return http.Response(
              jsonEncode({
                'transcript': {
                  'autoGenerated': generated,
                  'body': [
                    {
                      'type': 'heading',
                      'startMs': 0,
                      'endMs': 9000,
                      'line': 'Chapter'
                    },
                    {
                      'type': 'regular',
                      'startMs': 1000,
                      'endMs': 2000,
                      'line': 'Same &lt;words&gt; &amp; sound'
                    },
                    {
                      'type': 'regular',
                      'startMs': 3000,
                      'endMs': 4000,
                      'line': 'Same &lt;words&gt; &amp; sound'
                    },
                  ],
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          });
          addTearDown(client.close);
          final captions = await Service(httpClient: client)
              .getPlaybackCaptions('playing-video', selectedCaption,
                  server: server);

          expect(requests, hasLength(1));
          final request = requests.single;
          expect(request.url.origin, origin);
          expect(request.url.path, '/api/v1/transcripts/playing-video');
          expect(request.url.queryParameters['label'], selectedCaption.label);
          expect(request.headers['Cookie'], 'COMPANION_ID=7');
          final marker = request.headers[gatewayContextHeader];
          final expected = GatewayRequestContext.forAccount(
              server.profileId, server.accountId, server.url)!;
          expect(marker, expected.encoded);
          expect(captions, contains('00:00:01.000 --> 00:00:02.000'));
          expect(captions, contains('00:00:03.000 --> 00:00:04.000'));
          expect(captions, isNot(contains('Chapter')));
          expect(RegExp('Same &lt;words&gt; &amp; sound').allMatches(captions),
              hasLength(2));
          expect((await db.getCurrentlySelectedServer()).url,
              'https://inv.example');
        });
      }
    }

    test('caption fallback retains its account when the active server changes',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (requests.length == 1) {
          const replacement = Server(url: 'https://new-selection.example');
          await db.upsertServer(replacement);
          await db.useServer(replacement);
          return http.Response('{"error":"Not found"}', 404);
        }
        return http.Response(
          'WEBVTT\n\n00:01.000 --> 00:02.000\nRepeated\n\n'
          '00:03.000 --> 00:04.000\nRepeated\n\n',
          200,
          headers: {'content-type': 'text/vtt'},
        );
      });
      addTearDown(client.close);
      final captured = await db.getCurrentlySelectedServer();
      final captions = await Service(httpClient: client)
          .getPlaybackCaptions('video-id', caption, server: captured);
      expect(requests, hasLength(2));
      expect(requests.every((request) => request.url.host == 'inv.example'),
          isTrue);
      expect(requests.last.headers['Authorization'], 'Basic private-instance');
      expect(RegExp('Repeated').allMatches(captions), hasLength(2));
    });

    for (final advertised in [
      '/companion/api/v1/captions/video-id?label=English%20%28auto-generated%29&check=opaque%2Bcheck',
      'https://inv.example/companion/api/v1/captions/video-id?label=English%20%28auto-generated%29&check=opaque%2Bcheck',
      'https://youtube.com/api/timedtext?v=video-id',
      'https://other-instance.example/api/v1/captions/video-id',
      'https://credentials@inv.example/api/v1/captions/video-id',
      'http://inv.example/api/v1/captions/video-id',
      'https://inv.example:8443/api/v1/captions/video-id',
      'https://[invalid',
    ]) {
      test('playback fallback scopes advertised caption URL $advertised',
          () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) return http.Response('Unavailable', 404);
          return http.Response(
            'WEBVTT\n\n00:01.000 --> 00:02.000\nTrusted fallback\n\n',
            200,
            headers: {'content-type': 'text/vtt'},
          );
        });
        addTearDown(client.close);
        final captions = await Service(httpClient: client).getPlaybackCaptions(
          'video-id',
          Caption('English', 'en', advertised),
          server: await db.getCurrentlySelectedServer(),
        );
        expect(captions, contains('Trusted fallback'));
        expect(requests, hasLength(2));
        final fallback = requests.last;
        expect(fallback.url.origin, 'https://inv.example');
        expect(fallback.headers['Authorization'], 'Basic private-instance');
        final trusted = advertised.startsWith('/companion/') ||
            advertised.startsWith('https://inv.example/companion/');
        expect(
            fallback.url.path,
            trusted
                ? '/companion/api/v1/captions/video-id'
                : '/api/v1/captions/video-id');
        expect(fallback.url.queryParameters['check'],
            trusted ? 'opaque+check' : null);
        expect(fallback.url.queryParameters['label'],
            trusted ? 'English (auto-generated)' : 'English');
        if (trusted) {
          expect(fallback.url.query,
              'label=English%20%28auto-generated%29&check=opaque%2Bcheck');
        }
      });
    }

    for (final structured in [
      '{"transcript":{"body":[]}}',
      '{"transcript":{"body":[{"type":"heading","startMs":0,"endMs":1000,"line":"Chapter"}]}}',
      '{"transcript":{"body":[{"type":"regular","startMs":2000,"endMs":1000,"line":"Invalid"}]}}',
    ]) {
      test(
          'unplayable transcript tries captions and rejects an empty fallback ($structured)',
          () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return http.Response(requests.length == 1 ? structured : '', 200,
              headers: {
                'content-type':
                    requests.length == 1 ? 'application/json' : 'text/vtt'
              });
        });
        addTearDown(client.close);
        await expectLater(
          Service(httpClient: client).getPlaybackCaptions('video-id', caption,
              server: await db.getCurrentlySelectedServer()),
          throwsA(isA<InvidiousServiceError>()),
        );
        expect(requests, hasLength(3));
        expect(requests[1].url.path, '/api/v1/captions/video-id');
        expect(requests.last.url.path, '/watch');
      });
    }

    const captionBody =
        'WEBVTT\n\n00:01.000 --> 00:02.000\nCompanion caption\n\n';
    for (final origin in [
      'https://invidious.nerdvpn.de',
      'https://invidious.dvbeckwitt.duckdns.org',
    ]) {
      for (final generated in [false, true]) {
        test(
            'watch fallback selects exact caption on $origin (auto=$generated)',
            () async {
          final requests = <http.Request>[];
          final records = <LogRecord>[];
          final subscription = Logger('Service').onRecord.listen(records.add);
          addTearDown(subscription.cancel);
          final server = Server(
            url: origin,
            id: 'caption-account',
            customHeaders: {'Cookie': 'COMPANION_ID=7'},
          );
          final requestedLabel =
              generated ? 'English (auto-generated)' : 'English';
          final query = generated
              ? 'label=English%20%28auto-generated%29&check=private%2Bauto'
              : 'label=English&check=private%2Bmanual';
          final client = MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/watch') {
              expect(request.url.queryParameters['v'], 'video-id');
              return http.Response(
                  '''<video id="player">
                <track kind="captions" label="English" srclang="en"
                  src="/companion/api/v1/captions/video-id?label=English&amp;check=private%2Bmanual">
                <track kind="captions" label="English (auto-generated)" srclang="en"
                  src="/companion/api/v1/captions/video-id?label=English%20%28auto-generated%29&amp;check=private%2Bauto">
              </video>''',
                  200,
                  headers: {'content-type': 'text/html'});
            }
            if (request.url.path == '/companion/api/v1/captions/video-id') {
              expect(request.url.query, query);
              return http.Response(captionBody, 200,
                  headers: {'content-type': 'text/vtt'});
            }
            return request.url.path.startsWith('/api/v1/transcripts/')
                ? http.Response('{"error":"YouTube API error"}', 500,
                    headers: {'content-type': 'application/json'})
                : http.Response('WEBVTT\n\nKind: captions\nLanguage: en\n', 200,
                    headers: {'content-type': 'text/vtt'});
          });
          addTearDown(client.close);
          final result = await Service(httpClient: client).getPlaybackCaptions(
            'video-id',
            Caption(requestedLabel, 'en', '/api/v1/captions/video-id'),
            server: server,
          );
          expect(result, contains('Companion caption'));
          expect(requests, hasLength(4));
          for (final request in requests) {
            expect(request.url.origin, origin);
            expect(request.followRedirects, isFalse);
            expect(request.headers['Cookie'], 'COMPANION_ID=7');
            expect(request.headers[gatewayContextHeader],
                server.headersForUrl(server.url)![gatewayContextHeader]);
          }
          expect(
              records
                  .map((record) => '${record.message} ${record.error}')
                  .join(),
              isNot(contains('private')));
        });
      }
    }

    for (final languageCode in ['en', null]) {
      test(
          'watch fallback accepts a sole exact-label track without srclang (metadata=$languageCode)',
          () async {
        final requests = <http.Request>[];
        final server = Server(
          url: 'https://invidious.nerdvpn.de',
          id: 'caption-account',
          customHeaders: {'Cookie': 'COMPANION_ID=7'},
        );
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/watch') {
            return http.Response(
                '''<video id="player">
            <track kind="captions" label="English"
              src="/companion/api/v1/captions/video-id?label=English&amp;check=private%2Bmanual">
            <track kind="captions" label="English (auto-generated)"
              src="/companion/api/v1/captions/video-id?label=English%20%28auto-generated%29&amp;check=private%2Bauto">
          </video>''',
                200,
                headers: {'content-type': 'text/html'});
          }
          if (request.url.path == '/companion/api/v1/captions/video-id') {
            expect(request.url.query, 'label=English&check=private%2Bmanual');
            return http.Response(captionBody, 200,
                headers: {'content-type': 'text/vtt'});
          }
          return http.Response('', 500);
        });
        addTearDown(client.close);

        final result = await Service(httpClient: client).getPlaybackCaptions(
          'video-id',
          Caption('English', languageCode, '/api/v1/captions/video-id'),
          server: server,
        );

        expect(result, contains('Companion caption'));
        expect(requests, hasLength(4));
        for (final request in requests) {
          expect(request.url.origin, server.url);
          expect(request.followRedirects, isFalse);
          expect(request.headers['Cookie'], 'COMPANION_ID=7');
          expect(request.headers[gatewayContextHeader],
              server.headersForUrl(server.url)![gatewayContextHeader]);
        }
      });
    }

    for (final fixture in [
      (language: null, attribute: '', count: 2),
      (language: '', attribute: ' srclang=""', count: 1),
    ]) {
      test(
          'watch fallback rejects ambiguous or empty language metadata (${fixture.language})',
          () async {
        final requests = <http.Request>[];
        final track =
            '<track kind="captions" label="English"${fixture.attribute} '
            'src="/companion/api/v1/captions/video-id?check=same">';
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.path == '/watch') {
            return http.Response(
                '<video id="player">${List.filled(fixture.count, track).join()}</video>',
                200,
                headers: {'content-type': 'text/html'});
          }
          if (request.url.path == '/companion/api/v1/captions/video-id') {
            return http.Response(captionBody, 200,
                headers: {'content-type': 'text/vtt'});
          }
          return http.Response('', 500);
        });
        addTearDown(client.close);

        await expectLater(
          Service(httpClient: client).getPlaybackCaptions('video-id',
              Caption('English', fixture.language, '/api/v1/captions/video-id'),
              server: await db.getCurrentlySelectedServer()),
          throwsA(isA<InvidiousServiceError>()),
        );
        expect(requests, hasLength(3));
        expect(requests.last.url.path, '/watch');
      });
    }

    for (final track in [
      '<track kind="captions" label="English" srclang="en" src="https://outside.example/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" srclang="en" src="http://inv.example/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" srclang="en" src="https://user@inv.example/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" srclang="en" src="/companion/api/v1/captions/another-video?check=secret">',
      '<track kind="captions" label="English (auto-generated)" srclang="en" src="/companion/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" srclang="de" src="/companion/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" srclang="en" src="/companion/api/v1/captions/video-id?check=first">'
          '<track kind="captions" label="English" srclang="en" src="/companion/api/v1/captions/video-id?check=second">',
      '<track kind="captions" label="English" srclang="" src="/companion/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" src="https://outside.example/api/v1/captions/video-id?check=secret">',
      '<track kind="captions" label="English" src="/companion/api/v1/captions/video-id?check=first">'
          '<track kind="captions" label="English" src="/companion/api/v1/captions/video-id?check=second">',
      '<track kind="captions" label="English" src="/companion/api/v1/captions/video-id?check=same">'
          '<track kind="captions" label="English" src="/companion/api/v1/captions/video-id?check=same">',
      '<track kind="captions" label="English" src="/companion/api/v1/captions/video-id?check=first">'
          '<track kind="captions" label="English" srclang="de" src="/companion/api/v1/captions/video-id?check=second">',
      '<track kind="captions" label="English" src="/companion/api/v1/captions/video-id?check=first">'
          '<track kind="captions" label="English" src="https://outside.example/api/v1/captions/video-id?check=second">',
    ]) {
      test('watch fallback rejects an unsafe or different track $track',
          () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return request.url.path == '/watch'
              ? http.Response('<video id="player">$track</video>', 200,
                  headers: {'content-type': 'text/html'})
              : http.Response('', 500);
        });
        addTearDown(client.close);
        await expectLater(
          Service(httpClient: client).getPlaybackCaptions(
              'video-id', Caption('English', 'en', '/api/v1/captions/video-id'),
              server: await db.getCurrentlySelectedServer()),
          throwsA(isA<InvidiousServiceError>()),
        );
        expect(requests, hasLength(3));
        expect(requests.last.url.path, '/watch');
        expect(requests.every((request) => !request.followRedirects), isTrue);
      });
    }

    for (final redirectAt in [
      '/watch',
      '/companion/api/v1/captions/video-id'
    ]) {
      test('watch fallback never follows a redirect from $redirectAt',
          () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.path == redirectAt) {
            return http.Response('', 302,
                headers: {'location': 'https://youtube.com/api/timedtext'});
          }
          if (request.url.path == '/watch') {
            return http.Response('''<video id="player"><track kind="captions"
                label="English" srclang="en"
                src="/companion/api/v1/captions/video-id?check=private"></video>''',
                200);
          }
          return http.Response('', 500);
        });
        addTearDown(client.close);
        await expectLater(
          Service(httpClient: client).getPlaybackCaptions(
              'video-id', Caption('English', 'en', '/api/v1/captions/video-id'),
              server: await db.getCurrentlySelectedServer()),
          throwsA(isA<InvidiousServiceError>()),
        );
        expect(requests, hasLength(redirectAt == '/watch' ? 3 : 4));
        expect(requests.every((request) => request.url.host == 'inv.example'),
            isTrue);
      });
    }

    for (final refusal in [
      for (final at in [1, 2])
        for (final status in [401, 403, 429])
          for (final malformed in [false, true])
            (at: at, status: status, malformed: malformed),
    ]) {
      final refusedAt = refusal.at;
      test(
          'caption access ${refusal.status} at request $refusedAt stops all fallback (malformed=${refusal.malformed})',
          () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          return http.Response.bytes(refusal.malformed ? [0xff] : [],
              requests.length == refusedAt ? refusal.status : 500,
              headers:
                  requests.length == refusedAt ? {'retry-after': '60'} : {});
        });
        addTearDown(client.close);
        await expectLater(
          Service(httpClient: client).getPlaybackCaptions('video-id', caption,
              server: await db.getCurrentlySelectedServer()),
          throwsA(isA<InvidiousServiceError>()
              .having((e) => e.statusCode, 'status', refusal.status)
              .having((e) => e.retryAfter, 'retry delay',
                  const Duration(seconds: 60))),
        );
        expect(requests, hasLength(refusedAt));
      });
    }

    for (final refusedAt in [1, 2]) {
      for (final retryAfter in ['60', 'invalid']) {
        test(
            'caption cooldown at request $refusedAt stops fallback ($retryAfter)',
            () async {
          var calls = 0;
          final client = MockClient((_) async {
            calls++;
            return calls == refusedAt
                ? http.Response.bytes([0xff], 503,
                    headers: {'retry-after': retryAfter})
                : http.Response('', 500);
          });
          addTearDown(client.close);
          await expectLater(
            Service(httpClient: client).getPlaybackCaptions('video-id', caption,
                server: await db.getCurrentlySelectedServer()),
            throwsA(isA<InvidiousServiceError>()
                .having((e) => e.statusCode, 'status', 503)
                .having((e) => e.retryAfterIsInvalid, 'invalid cooldown',
                    retryAfter == 'invalid')
                .having((e) => e.retryAfter, 'retry delay',
                    retryAfter == '60' ? const Duration(seconds: 60) : null)),
          );
          expect(calls, refusedAt);
        });
      }
      for (final failure in [
        const SocketException('Direct official endpoint blocked'),
        const HandshakeException('Certificate rejected'),
      ]) {
        test('caption ${failure.runtimeType} at request $refusedAt is terminal',
            () async {
          var calls = 0;
          final client = MockClient((_) async {
            if (++calls == refusedAt) throw failure;
            return http.Response('', 500);
          });
          addTearDown(client.close);
          await expectLater(
            Service(httpClient: client).getPlaybackCaptions('video-id', caption,
                server: await db.getCurrentlySelectedServer()),
            throwsA(same(failure)),
          );
          expect(calls, refusedAt);
        });
      }
    }

    test('an empty companion response fails after the fourth request',
        () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/watch') {
          return http.Response('''<video id="player"><track kind="captions"
              label="English" srclang="en"
              src="/companion/api/v1/captions/video-id?check=private"></video>''',
              200);
        }
        return http.Response('WEBVTT\n\nKind: captions\n', 200,
            headers: {'content-type': 'text/vtt'});
      });
      addTearDown(client.close);
      await expectLater(
        Service(httpClient: client).getPlaybackCaptions(
            'video-id', Caption('English', 'en', '/api/v1/captions/video-id'),
            server: await db.getCurrentlySelectedServer()),
        throwsA(isA<InvidiousServiceError>()),
      );
      expect(requests, hasLength(4));
    });

    test('streamed refusal wins even when its body and cancellation stall',
        () async {
      final cancellation = Completer<void>();
      var cancelled = false;
      final body = StreamController<List<int>>(onCancel: () {
        cancelled = true;
        return cancellation.future;
      });
      var calls = 0;
      final client = MockClient.streaming((_, __) async {
        calls++;
        return http.StreamedResponse(body.stream, 429,
            headers: {'retry-after': '60'});
      });
      addTearDown(client.close);
      try {
        await expectLater(
          Service(httpClient: client)
              .getPlaybackCaptions('video-id', caption,
                  server: await db.getCurrentlySelectedServer())
              .timeout(const Duration(seconds: 1)),
          throwsA(isA<InvidiousServiceError>()
              .having((e) => e.statusCode, 'status', 429)
              .having((e) => e.retryAfter, 'retry delay',
                  const Duration(seconds: 60))),
        );
        expect(calls, 1);
        expect(cancelled, isTrue);
      } finally {
        cancellation.complete();
        await body.close();
      }
    });

    for (final oversized in [false, true]) {
      testWidgets(
          'caption fallback releases a ${oversized ? 'too large' : 'timed-out'} response',
          (tester) async {
        var cancelled = false;
        final body = StreamController<List<int>>(onCancel: () {
          cancelled = true;
        });
        if (oversized) body.add(Uint8List(4 * 1024 * 1024 + 1));
        var calls = 0;
        final client = MockClient.streaming((_, __) async {
          if (++calls == 1) return http.StreamedResponse(body.stream, 200);
          return http.StreamedResponse(
              Stream.value(utf8.encode(captionBody)), 200);
        });
        addTearDown(client.close);
        String? result;
        Object? failure;
        unawaited(Service(httpClient: client)
            .getPlaybackCaptions('video-id', caption,
                server: const Server(url: 'https://instance.example'))
            .then<void>((value) => result = value,
                onError: (Object error) => failure = error));
        try {
          await tester.pump();
          if (!oversized) await tester.pump(const Duration(seconds: 15));
          await tester.pump();
          expect(cancelled, isTrue);
          expect(failure, isNull);
          expect(result, contains('Companion caption'));
          expect(calls, 2);
        } finally {
          unawaited(body.close());
          await tester.pump();
        }
      });
    }

    for (final failure in [
      const NerdVpnAccessRequired('waiting'),
      const GatewayAuthenticationRequired(),
    ]) {
      test('native caption access failure is preserved: ${failure.runtimeType}',
          () async {
        var calls = 0;
        final client = MockClient((_) async {
          calls++;
          throw failure;
        });
        addTearDown(client.close);
        await expectLater(
          Service(httpClient: client).getPlaybackCaptions('video-id', caption,
              server: await db.getCurrentlySelectedServer()),
          throwsA(same(failure)),
        );
        expect(calls, 1);
      });
    }
  });

  group('subscription writes', () {
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      const server = Server(
        url: 'https://inv.example',
        authToken: 'invidious-token',
      );
      await db.upsertServer(server);
      await db.useServer(server);
    });

    tearDown(() async {
      service = Service();
      await db.close();
    });

    test('does not silently convert a 403 subscribe response to false',
        () async {
      final client = MockClient((request) async => http.Response(
            '{"error":"Invalid token"}',
            403,
            headers: {'content-type': 'application/json'},
          ));
      final testService = Service(httpClient: client);

      await expectLater(
        testService.subscribe('UC123'),
        throwsA(isA<InvidiousServiceError>()),
      );
    });

    test('accepts a 204 unsubscribe response', () async {
      final client = MockClient((request) async => http.Response('', 204));
      final testService = Service(httpClient: client);

      expect(await testService.unSubscribe('UC123'), isTrue);
    });

    test('validates stored credentials with the subscriptions endpoint',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final testService = Service(httpClient: client);

      expect(await testService.validateCurrentSession(), isTrue);
      expect(captured.url.path, '/api/v1/auth/subscriptions');
      expect(captured.headers['Authorization'], 'Bearer invidious-token');
    });

    test('startup validation stops waiting and ignores a late rejection',
        () async {
      final response = Completer<http.Response>();
      final client = MockClient((_) => response.future);
      addTearDown(client.close);
      var finished = false;
      final pending = Service(httpClient: client)
          .validateCurrentSessionSafely()
          .then((_) => finished = true);
      await Future<void>.delayed(const Duration(seconds: 6));
      final finishedAtDeadline = finished;
      response.complete(http.Response('{"error":"Invalid token"}', 403,
          headers: {'content-type': 'application/json'}));
      await pending;

      expect(finishedAtDeadline, isTrue);
      expect(db.getServer('https://inv.example')!.authToken, 'invidious-token');
    });

    test('clears stored credentials after an Invidious JSON 403', () async {
      final client = MockClient((request) async => http.Response(
            '{"error":"Invalid token"}',
            403,
            headers: {'content-type': 'application/json'},
          ));
      final testService = Service(httpClient: client);

      expect(await testService.validateCurrentSession(), isFalse);
      expect(db.getServer('https://inv.example')!.authToken, isNull);
    });

    test('keeps credentials when an outer proxy returns HTML', () async {
      final client = MockClient((request) async => http.Response(
            '<a href="https://auth.example/login">Sign in</a>',
            403,
            headers: {'content-type': 'text/html'},
          ));
      final testService = Service(httpClient: client);

      await expectLater(
        testService.validateCurrentSession(),
        throwsA(
          isA<InvidiousServiceError>().having(
            (error) => error.responseWasHtml,
            'responseWasHtml',
            isTrue,
          ),
        ),
      );
      expect(
        db.getServer('https://inv.example')!.authToken,
        'invidious-token',
      );
    });
  });

  group('Invidious request handling', () {
    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      await db.upsertServer(const Server(url: 'https://inv.example'));
    });
    tearDown(() => db.close());

    test('bodyless video GET requests JSON without a Content-Type', () async {
      final client = MockClient((request) async {
        expect(request.headers['Accept'], 'application/json');
        expect(request.headers.containsKey('Content-Type'), isFalse);
        return http.Response('{"videoId":"video-id"}', 200);
      });
      await Service(httpClient: client).getVideo('video-id');
    });

    test('simultaneous video requests share HTTP work but not decoded models',
        () async {
      var calls = 0;
      final response = Completer<http.Response>();
      final client = MockClient((_) {
        calls++;
        return response.future;
      });
      final service = Service(httpClient: client);
      final admitted = Completer<void>();
      var admittedRequests = 0;
      void onRequest(BackendPlayback _) {
        if (++admittedRequests == 2) admitted.complete();
      }

      final first = service.getVideo('video-id', onBackendRequest: onRequest);
      final second = service.getVideo('video-id', onBackendRequest: onRequest);
      // Both database-backed requests must reach the HTTP boundary before the
      // response is released; an event-loop delay does not establish overlap.
      await admitted.future;
      response.complete(http.Response('{"videoId":"video-id"}', 200));
      final videos = await Future.wait([first, second]);
      expect(calls, 1);
      expect(identical(videos.first, videos.last), isFalse);
      await service.getVideo('video-id');
      expect(calls, 2, reason: 'Playback URLs must not stay cached');
    });

    test('repeated public browsing reuses a recent response', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('[{"videoId":"video-id"}]', 200);
      });
      final service = Service(httpClient: client);
      await service.getPopular();
      await service.getPopular();
      expect(calls, 1);
    });

    for (final endpoint in ['popular', 'trending', 'search']) {
      testWidgets(
          'concurrent $endpoint requests share work and decode separately',
          (tester) async {
        var calls = 0;
        final response = Completer<http.Response>();
        final client = MockClient((_) {
          calls++;
          return response.future;
        });
        addTearDown(client.close);
        final api = Service(httpClient: client);
        Future<List<Video>> load() async => switch (endpoint) {
              'popular' => await api.getPopular(),
              'trending' => await api.getTrending(),
              _ => (await api.search('query')).videos,
            };
        final first = load();
        final second = load();
        await tester.pump();
        response.complete(http.Response(
            '[{"type":"video","videoId":"video-id"}]', 200,
            headers: {'cache-control': 'no-store'}));
        await tester.pump();
        final lists = await Future.wait([first, second]);

        expect(calls, 1);
        expect(identical(lists.first.single, lists.last.single), isFalse);
        lists.first.clear();
        expect(lists.last, hasLength(1));
        final fresh = load();
        await tester.pump();
        await fresh;
        expect(calls, 2, reason: 'No-store responses must not be retained');
      });
    }

    testWidgets(
        'obsolete browsing cannot repopulate cache or remove newer work',
        (tester) async {
      var calls = 0;
      final oldResponse = Completer<http.Response>();
      final newResponse = Completer<http.Response>();
      final client = MockClient(
          (_) => ++calls == 1 ? oldResponse.future : newResponse.future);
      addTearDown(client.close);
      final api = Service(httpClient: client);
      final old = api.getPopular();
      await tester.pump();
      api.clearSessionCaches();
      final current = api.getPopular();
      await tester.pump();
      oldResponse.complete(http.Response('[{"videoId":"old"}]', 200));
      await tester.pump();
      await old;
      final overlapping = api.getPopular();
      await tester.pump();
      newResponse.complete(http.Response('[{"videoId":"new"}]', 200));
      await tester.pump();
      final results = await Future.wait([current, overlapping]);

      expect(calls, 2);
      expect(results.map((items) => items.single.videoId), ['new', 'new']);
      final cached = api.getPopular();
      await tester.pump();
      expect((await cached).single.videoId, 'new');
      expect(calls, 2);
    });

    test('a GET retries a short explicit rate limit once', () async {
      var calls = 0;
      final client = MockClient((_) async => ++calls == 1
          ? http.Response('Too many requests', 429,
              headers: {'retry-after': '0'})
          : http.Response('[{"videoId":"video-id"}]', 200));
      expect(await Service(httpClient: client).getPopular(), hasLength(1));
      expect(calls, 2);
    });

    test('honors custom Accept casing and keeps JSON mutation Content-Type',
        () async {
      await db.upsertServer(const Server(
          url: 'https://inv.example',
          authToken: 'token',
          customHeaders: {'aCcEpT': 'application/vnd.custom+json'}));
      final client = MockClient((request) async {
        expect(request.headers['Accept'], 'application/vnd.custom+json');
        expect(
            request.headers.keys.where((key) => key.toLowerCase() == 'accept'),
            hasLength(1));
        expect(request.headers['Content-Type'], startsWith('application/json'));
        expect(request.headers['Authorization'], 'Bearer token');
        expect(request.method, 'POST');
        return http.Response('{"playlistId":"PL-test"}', 201);
      });
      expect(
          await Service(httpClient: client).createPlayList('test', 'private'),
          'PL-test');
    });

    test('failed shared video requests are released for the next attempt',
        () async {
      var calls = 0;
      final failed = Completer<http.Response>();
      final client = MockClient((_) => ++calls == 1
          ? failed.future
          : Future.value(http.Response('{"videoId":"video-id"}', 200)));
      final service = Service(httpClient: client);
      final attempts = [
        expectLater(
            service.getVideo('video-id'), throwsA(isA<http.ClientException>())),
        expectLater(
            service.getVideo('video-id'), throwsA(isA<http.ClientException>())),
      ];
      await Future<void>.delayed(Duration.zero);
      failed.completeError(http.ClientException('Connection closed'));
      await Future.wait(attempts);
      expect(calls, 1);
      await service.getVideo('video-id');
      expect(calls, 2);
    });

    testWidgets('a stalled shared video request expires so retry can recover',
        (tester) async {
      var calls = 0;
      final service = Service(
          httpClient: MockClient((_) => ++calls == 1
              ? Completer<http.Response>().future
              : Future.value(http.Response('{"videoId":"video-id"}', 200))));
      final failed = expectLater(
          service.getVideo('video-id'), throwsA(isA<TimeoutException>()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await failed;
      final retry = service.getVideo('video-id');
      await tester.pump();
      expect((await retry).videoId, 'video-id');
      expect(calls, 2);
    });

    test(
        'video request sharing stays separate for different hosts and accounts',
        () async {
      var calls = 0;
      final pending = Completer<http.Response>();
      final service = Service(httpClient: MockClient((_) {
        calls++;
        return pending.future;
      }));
      final requests = [
        service.getVideo('video-id',
            serverOverride:
                const Server(url: 'https://one.example', authToken: 'one')),
        service.getVideo('video-id',
            serverOverride:
                const Server(url: 'https://one.example', authToken: 'two')),
        service.getVideo('video-id',
            serverOverride:
                const Server(url: 'https://two.example', authToken: 'one')),
      ];
      await Future<void>.delayed(Duration.zero);
      pending.complete(http.Response('{"videoId":"video-id"}', 200));
      await Future.wait(requests);
      expect(calls, 3);
    });

    test('public cache expires and callers receive separate decoded lists',
        () async {
      var now = DateTime.utc(2026, 10, 9);
      var calls = 0;
      final service = Service(
          now: () => now,
          httpClient: MockClient((_) async {
            calls++;
            return http.Response('[{"videoId":"video-id"}]', 200);
          }));
      (await service.getPopular()).clear();
      now = now.add(const Duration(seconds: 10));
      expect(await service.getPopular(), hasLength(1));
      expect(calls, 1);
      now = now.add(const Duration(seconds: 6));
      await service.getPopular();
      expect(calls, 2);
    });

    test('public cache is bounded to twenty requests', () async {
      var calls = 0;
      final service = Service(httpClient: MockClient((_) async {
        calls++;
        return http.Response('[{"type":"video","videoId":"video-id"}]', 200);
      }));
      for (var index = 0; index < 21; index++) {
        await service.search('query-$index');
      }
      await service.search('query-20');
      expect(calls, 21);
      await service.search('query-0');
      expect(calls, 22);
    });

    test(
        'public cache separates accounts and ignores obsolete proxy preference',
        () async {
      var calls = 0;
      final service = Service(httpClient: MockClient((_) async {
        calls++;
        return http.Response('[{"videoId":"video-id"}]', 200);
      }));
      const configurations = [
        Server(url: 'https://inv.example'),
        Server(url: 'https://other.example'),
        Server(url: 'https://inv.example', authToken: 'first'),
        Server(url: 'https://inv.example', authToken: 'second'),
        Server(url: 'https://inv.example', sidCookie: 'SID=first'),
        Server(url: 'https://inv.example', sidCookie: 'SID=second'),
        Server(
            url: 'https://inv.example',
            customHeaders: {'X-Instance-Key': 'first'}),
        Server(
            url: 'https://inv.example',
            customHeaders: {'X-Instance-Key': 'second'}),
      ];
      for (final server in configurations) {
        await db.upsertServer(server);
        await db.useServer(server);
        await service.getPopular();
        await service.getPopular();
      }
      expect(calls, configurations.length);
      await db.saveSetting(SettingsValue(useProxySettingName, 'false'));
      await service.getPopular();
      expect(calls, configurations.length);
    });

    test('errors, empty data, HTML and invalid models are not cached',
        () async {
      for (final response in [
        http.Response('Unavailable', 503),
        http.Response('', 200),
        http.Response('[]', 200),
        http.Response('{bad-json', 200),
        http.Response('<html>Challenge</html>', 200),
        http.Response('[{"videoId":"id"}]', 200,
            headers: {'content-type': 'text/html'}),
        http.Response('[{"videoId":"id"}]', 200,
            headers: {'cache-control': 'no-store'}),
        http.Response('[{"error":"Unavailable"}]', 200),
      ]) {
        var calls = 0;
        final service = Service(httpClient: MockClient((_) async {
          calls++;
          return response;
        }));
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            await service.getPopular();
          } catch (_) {}
        }
        expect(calls, 2, reason: 'Must not retain ${response.body}');
      }
    });

    test('authenticated reads stay fresh across an account mutation', () async {
      await db.upsertServer(
          const Server(url: 'https://inv.example', authToken: 'token'));
      final methods = <String>[];
      final service = Service(httpClient: MockClient((request) async {
        methods.add(request.method);
        return http.Response(request.method == 'GET' ? '[]' : '',
            request.method == 'GET' ? 200 : 204);
      }));
      await service.getSubscriptions();
      await service.subscribe('UC-test');
      await service.getSubscriptions();
      expect(methods, ['GET', 'POST', 'GET']);
    });

    test('integer and HTTP-date cooldowns delay one retry by the server value',
        () async {
      final now = DateTime.utc(2026, 10, 9, 12);
      for (final value in [
        '2',
        HttpDate.format(now.add(const Duration(seconds: 1))),
        HttpDate.format(now.subtract(const Duration(seconds: 1)))
      ]) {
        var calls = 0;
        final delays = <Duration>[];
        final service = Service(
            now: () => now,
            wait: (delay) async => delays.add(delay),
            httpClient: MockClient((_) async => ++calls == 1
                ? http.Response('', 429, headers: {'retry-after': value})
                : http.Response('[{"videoId":"id"}]', 200)));
        await service.getPopular();
        expect(calls, 2);
        expect(
            delays,
            value == '2'
                ? [const Duration(seconds: 2)]
                : value == HttpDate.format(now.add(const Duration(seconds: 1)))
                    ? [const Duration(seconds: 1)]
                    : isEmpty);
      }
    });

    test('long, absent and malformed cooldowns return 429 without retrying',
        () async {
      final now = DateTime.utc(2026, 10, 9, 12);
      for (final value in <String?>[
        '30',
        HttpDate.format(now.add(const Duration(minutes: 1))),
        null,
        '',
        'soon',
        'Fri, 1',
        '-1',
        '+1',
        '1.5',
        '99999999999999999999999'
      ]) {
        var calls = 0;
        final service = Service(
            now: () => now,
            wait: (_) async =>
                fail('Do not wait for an invalid or long cooldown'),
            httpClient: MockClient((_) async {
              calls++;
              return http.Response('Blocked', 429,
                  headers: {if (value != null) 'retry-after': value});
            }));
        final expectedDelay = value == '30'
            ? const Duration(seconds: 30)
            : value == HttpDate.format(now.add(const Duration(minutes: 1)))
                ? const Duration(minutes: 1)
                : null;
        await expectLater(
            service.getPopular(),
            throwsA(isA<InvidiousServiceError>()
                .having((error) => error.statusCode, 'status', 429)
                .having(
                    (error) => error.retryAfter, 'retryAfter', expectedDelay)),
            reason: value);
        expect(calls, 1);
      }
    });

    test('repeated 429 stops after one automatic retry', () async {
      var calls = 0;
      final service = Service(httpClient: MockClient((_) async {
        calls++;
        return http.Response('', 429, headers: {'retry-after': '0'});
      }));
      await expectLater(
          service.getPopular(),
          throwsA(isA<InvidiousServiceError>()
              .having((error) => error.isRateLimited, 'rate limited', isTrue)));
      expect(calls, 2);
    });

    test('401 and 403 are never automatically retried', () async {
      for (final status in [401, 403]) {
        var calls = 0;
        final service = Service(httpClient: MockClient((_) async {
          calls++;
          return http.Response('{"error":"API access denied"}', status,
              headers: {'retry-after': '0'});
        }));
        await expectLater(
            service.getPopular(),
            throwsA(isA<InvidiousServiceError>()
                .having((error) => error.statusCode, 'status', status)));
        expect(calls, 1);
      }
    });

    test('POST, DELETE and external API rate limits are not replayed',
        () async {
      await db.upsertServer(
          const Server(url: 'https://inv.example', authToken: 'token'));
      final requests = <http.Request>[];
      final service = Service(httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('', 429, headers: {'retry-after': '0'});
      }));
      for (final operation in [
        () => service.subscribe('UC-test'),
        () => service.unSubscribe('UC-test'),
        () => service.getDislikes('video-id')
      ]) {
        await expectLater(
            operation(),
            throwsA(isA<InvidiousServiceError>().having(
                (error) => error.isRateLimited, 'rate limited', isTrue)));
      }
      expect(
          requests.map((request) => request.method), ['POST', 'DELETE', 'GET']);
      expect(requests.last.url.host, 'returnyoutubedislikeapi.com');
    });

    test(
        'instance validation preserves HTTP errors and classifies invalid stats',
        () async {
      for (final response in [
        http.Response('', 200),
        http.Response('[]', 200),
        http.Response('Denied', 403),
        http.Response('', 429, headers: {'retry-after': '30'})
      ]) {
        final service = Service(httpClient: MockClient((request) async {
          expect(request.headers['Accept'], 'application/json');
          return response;
        }));
        await expectLater(
            service.validateServer('https://inv.example', {}),
            throwsA(isA<InvidiousServiceError>().having(
                (error) => error.statusCode, 'status', response.statusCode)));
      }
    });
  });
}
