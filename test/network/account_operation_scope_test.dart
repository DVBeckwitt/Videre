import 'dart:async';
import 'dart:convert';

import 'package:clipious/globals.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/app_logs.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/db/video_filter.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/history_video_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _SelectionGate {
  final started = Completer<void>();
  final release = Completer<void>();
  bool pending = true;
}

/// Delay one completed account read while retaining real profile storage.
class _DelayedSelection extends Fake implements IDbClient {
  final IDbClient delegate;
  final _SelectionGate gate;

  _DelayedSelection(this.delegate, this.gate);

  @override
  String get profileId => delegate.profileId;

  @override
  IDbClient forProfile(String id) =>
      _DelayedSelection(delegate.forProfile(id), gate);

  @override
  Server? getAccount(String accountId) => delegate.getAccount(accountId);

  @override
  Future<Server> getCurrentlySelectedServer() async {
    final delay = gate.pending;
    gate.pending = false;
    final selected = await delegate.getCurrentlySelectedServer();
    if (delay) {
      gate.started.complete();
      await gate.release.future;
    }
    return selected;
  }

  @override
  Future<bool> isLoggedInToCurrentServer() async {
    final selected = await getCurrentlySelectedServer();
    return (selected.authToken?.isNotEmpty ?? false) ||
        (selected.sidCookie?.isNotEmpty ?? false);
  }

  @override
  SettingsValue? getSettings(String name) => delegate.getSettings(name);

  @override
  List<VideoFilter> getAllFilters() => delegate.getAllFilters();

  @override
  List<HistoryVideoCache> getLocalHistory() => delegate.getLocalHistory();

  @override
  Future<void> clearLocalHistory() => delegate.clearLocalHistory();

  @override
  Future<void> deleteLocalHistory(String videoId) =>
      delegate.deleteLocalHistory(videoId);

  @override
  Future<void> upsertServer(Server server) async =>
      await delegate.upsertServer(server);

  @override
  Future<void> insertLogs(AppLog log) => delegate.insertLogs(log);
}

void main() {
  late SembastSqfDb database;
  late IDbClient origin;
  late IDbClient otherPerson;
  late Server nextAccount;
  late String otherProfileId;
  late _SelectionGate gate;
  late Service api;
  late MockClient client;
  final requests = <http.Request>[];
  const first = Server(
      url: 'https://instance.example', id: 'first', authToken: 'first-token');

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    await database.upsertServer(first);
    origin = database.forProfile(database.profileId);
    nextAccount = first.copyWith(id: 'next', authToken: 'next-token');
    await database.upsertServer(nextAccount);
    final person = await database.createProfile('Another person');
    otherProfileId = person.id;
    otherPerson = database.forProfile(person.id);
    await otherPerson.upsertServer(
        first.copyWith(profileId: person.id, authToken: 'other-person-token'));
    await origin.saveSetting(SettingsValue(
        localPlaylistsSetting,
        jsonEncode([
          {
            'playlistId': 'local:first',
            'title': 'First local',
            'author': '',
            'videoCount': 0
          }
        ])));
    await otherPerson.saveSetting(SettingsValue(
        localPlaylistsSetting,
        jsonEncode([
          {
            'playlistId': 'local:other',
            'title': 'Other local',
            'author': '',
            'videoCount': 0
          }
        ])));
    gate = _SelectionGate();
    db = _DelayedSelection(database, gate);
    requests.clear();
    client = MockClient((request) async {
      requests.add(request);
      if (request.url.path == '/api/v1/auth/subscriptions' &&
          request.method == 'GET') {
        return http.Response(
            '[{"author":"Original channel","authorId":"original-channel"}]',
            200);
      }
      if (request.url.path == '/api/v1/auth/history' &&
          request.method == 'GET') {
        return http.Response('["original-video"]', 200);
      }
      if (request.url.path == '/api/v1/auth/playlists') {
        final originRequest =
            request.headers['Authorization'] == 'Bearer first-token';
        return http.Response(
            jsonEncode([
              {
                'playlistId': originRequest ? 'remote:first' : 'remote:other',
                'title': 'Remote playlist',
                'author': '',
                'videoCount': 0,
              }
            ]),
            200);
      }
      return http.Response('{}', 200);
    });
    api = Service(httpClient: client);
  });

  tearDown(() async {
    client.close();
    await database.close();
  });

  Future<void> switchSelection(bool person) => person
      ? database.useProfile(otherProfileId)
      : database.useServer(nextAccount);

  final remoteOperations =
      <(String, Future<dynamic> Function(Service), String, String, dynamic)>[
    (
      'subscribe',
      (api) => api.subscribe('original-channel'),
      'POST',
      '/api/v1/auth/subscriptions/original-channel',
      true
    ),
    (
      'unsubscribe',
      (api) => api.unSubscribe('original-channel'),
      'DELETE',
      '/api/v1/auth/subscriptions/original-channel',
      true
    ),
    (
      'subscription status',
      (api) => api.isSubscribedToChannel('original-channel'),
      'GET',
      '/api/v1/auth/subscriptions',
      true
    ),
    (
      'subscription list',
      (api) => api.getSubscriptions(),
      'GET',
      '/api/v1/auth/subscriptions',
      null
    ),
    (
      'read history',
      (api) => api.getUserHistory(1, 20),
      'GET',
      '/api/v1/auth/history',
      ['original-video']
    ),
    (
      'clear history',
      (api) => api.clearUserHistory(),
      'DELETE',
      '/api/v1/auth/history',
      null
    ),
    (
      'delete history item',
      (api) => api.deleteFromUserHistory('original-video'),
      'DELETE',
      '/api/v1/auth/history/original-video',
      null
    ),
    (
      'validate session',
      (api) => api.validateCurrentSession(),
      'GET',
      '/api/v1/auth/subscriptions',
      true
    ),
  ];

  for (final person in [false, true]) {
    final transition = person ? 'profile' : 'account';
    for (final (label, operation, method, path, expected) in remoteOperations) {
      test('$label retains its starting account across a $transition switch',
          () async {
        final pending = operation(api);
        await gate.started.future;
        await switchSelection(person);
        gate.release.complete();
        final result = await pending;

        expect(requests.single.method, method);
        expect(requests.single.url.path, path);
        expect(requests.single.headers['Authorization'], 'Bearer first-token');
        if (expected != null) expect(result, expected);
      });
    }

    for (final postProcessing in [false, true]) {
      test(
          'playlists keep one owner across $transition switch, processing=$postProcessing',
          () async {
        final pending = api.getUserPlaylists(postProcessing: postProcessing);
        await gate.started.future;
        await switchSelection(person);
        gate.release.complete();
        final playlists = await pending;

        expect(requests.single.headers['Authorization'], 'Bearer first-token');
        expect(playlists.map((playlist) => playlist.playlistId),
            [localWatchLaterId, 'local:first', 'remote:first']);
      });
    }

    for (final action in ['read', 'clear', 'delete']) {
      test(
          'guest $action history stays in its profile during $transition switch',
          () async {
        await origin.upsertServer(
            origin.getServer(first.accountId)!.copyWith(authToken: null));
        await origin.upsertHistoryVideo(
            HistoryVideoCache('first-local', 'First local', '', ''));
        await otherPerson.upsertHistoryVideo(
            HistoryVideoCache('other-local', 'Other local', '', ''));
        final Future<dynamic> pending = switch (action) {
          'read' => api.getUserHistory(1, 20),
          'clear' => api.clearUserHistory(),
          _ => api.deleteFromUserHistory('first-local'),
        };
        await gate.started.future;
        await switchSelection(person);
        gate.release.complete();
        final result = await pending;

        expect(requests, isEmpty);
        if (action == 'read') {
          expect(result, ['first-local']);
        } else {
          expect(origin.getLocalHistory(), isEmpty);
        }
        expect(otherPerson.getLocalHistory().map((video) => video.videoId),
            ['other-local']);
      });
    }
  }

  test('an empty profile keeps local history and playlist fallbacks', () async {
    final empty = await database.createProfile('Local only');
    await database.useProfile(empty.id);
    db = database;
    await database.upsertHistoryVideo(
        HistoryVideoCache('local-only', 'Local only', '', ''));

    expect(await api.getUserHistory(1, 20), ['local-only']);
    expect((await api.getUserPlaylists()).single.playlistId, localWatchLaterId);
    await api.deleteFromUserHistory('local-only');
    await api.clearUserHistory();

    expect(database.getLocalHistory(), isEmpty);
    expect(requests, isEmpty);
  });
}
