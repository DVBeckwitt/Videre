import 'dart:async';

import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/playlists/models/playlist.dart';
import 'package:clipious/playlists/models/playlist_reference.dart';
import 'package:clipious/playlists/services/playlist_server_copy.dart';
import 'package:clipious/playlists/views/components/playlist_server_save_button.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Server extends Service {
  int creations = 0;
  final videos = <String>[];
  bool loseAcknowledgment = false;
  bool failCreation = false;
  Completer<void>? pending;
  final accounts = <Server>[];
  final appendAttempts = <String>[];
  final failures = <int, Object>{};
  final missingDestinations = <String>{};
  bool commitBeforeError = false;
  FutureOr<void> Function()? onAppendError;

  @override
  Future<String> createServerPlaylist(
      String name, String privacy, Server server) async {
    expect(privacy, 'private');
    accounts.add(server);
    creations++;
    if (failCreation) throw StateError('Connection closed');
    if (creations > 1) videos.clear();
    return creations == 1 ? 'IVPcopy' : 'IVPcopy$creations';
  }

  @override
  Future<Playlist> getServerPlaylist(String playlistId,
      {int? page, Server? serverOverride}) async {
    accounts.add(serverOverride!);
    if (missingDestinations.contains(playlistId)) {
      throw InvidiousServiceError('Playlist does not exist', statusCode: 404);
    }
    return Playlist(
        title: 'Saved',
        playlistId: playlistId,
        author: '',
        videoCount: videos.length,
        videos: videos
            .skip(((page ?? 1) - 1) * 2)
            .take(2)
            .map((id) => Video(videoId: id))
            .toList());
  }

  @override
  Future<void> addVideoToServerPlaylist(
      String playListId, String videoId, Server server) async {
    accounts.add(server);
    appendAttempts.add(videoId);
    final error = failures[appendAttempts.length];
    if (error != null) {
      if (commitBeforeError) videos.add(videoId);
      await onAppendError?.call();
      throw error;
    }
    videos.add(videoId);
    await pending?.future;
    if (loseAcknowledgment) {
      loseAcknowledgment = false;
      throw StateError('Response lost after saving');
    }
  }
}

void main() {
  const server =
      Server(url: 'https://playlist.example', authToken: 'test-token');
  const playlist = Playlist(
      title: 'Saved',
      playlistId: 'local:saved',
      author: '',
      videoCount: 3,
      videos: [
        Video(videoId: 'first'),
        Video(videoId: 'first'),
        Video(videoId: 'second')
      ]);
  late _Server client;
  PlaylistServerCopy copy({Playlist source = playlist}) => PlaylistServerCopy(
      database: db.forProfile(db.profileId),
      client: client,
      playlist: source,
      reference: PlaylistReference.forPlaylist(source, db),
      server: server);

  Future<void> showCopy(WidgetTester tester, Playlist source) =>
      tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlaylistServerSaveButton(
            reference: PlaylistReference.forPlaylist(source, db),
            playlist: source,
          ),
        ),
      ));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    await db.upsertServer(server);
    client = _Server();
  });
  tearDown(() async => db.close());

  test('creates a private copy and preserves repeated occurrences', () async {
    final progress = <int>[];
    expect(await copy().save(onProgress: (saved, _) => progress.add(saved)),
        'IVPcopy');
    expect(client.videos, ['first', 'first', 'second']);
    expect(progress, [0, 1, 2, 3]);
    expect(client.accounts.every((account) => account == server), isTrue);
    await copy().save();
    expect(client.creations, 1);
    expect(client.videos, ['first', 'first', 'second']);
  });

  test('reopening and retrying reconciles a lost append acknowledgment',
      () async {
    client.loseAcknowledgment = true;
    await expectLater(copy().save(), throwsStateError);
    expect(client.videos, ['first']);
    await copy().save();
    expect(client.creations, 1);
    expect(client.videos, ['first', 'first', 'second']);
  });

  for (final committed in [false, true]) {
    test('reconciles one append HTTP 500 (already saved: $committed)',
        () async {
      client.commitBeforeError = committed;
      client.failures[2] =
          InvidiousServiceError('Backend failed', statusCode: 500);
      await copy().save();
      expect(client.videos, ['first', 'first', 'second']);
      expect(client.appendAttempts,
          ['first', 'first', if (!committed) 'first', 'second']);
      expect(client.creations, 1);
    });
  }

  test('one automatic recovery budget covers the entire copy', () async {
    final failure = InvidiousServiceError('Backend failed', statusCode: 500);
    client.failures.addAll({1: failure, 3: failure});
    await expectLater(
        copy().save(),
        throwsA(isA<PlaylistTrackSaveFailure>()
            .having((error) => error.index, 'track index', 1)
            .having((error) => error.statusCode, 'HTTP status', 500)));
    expect(client.videos, ['first']);
    expect(client.appendAttempts.length, 3);
    await copy().save();
    expect(client.videos, ['first', 'first', 'second']);
    expect(client.creations, 1);
  });

  for (final edited in [
    <String>[],
    ['first', 'first', 'second'],
    ['different']
  ]) {
    test('reconciliation stops if another client changes the prefix to $edited',
        () async {
      client.failures[2] =
          InvidiousServiceError('Backend failed', statusCode: 500);
      client.onAppendError = () => client.videos
        ..clear()
        ..addAll(edited);
      await expectLater(copy().save(), throwsStateError);
      expect(client.appendAttempts, ['first', 'first']);
      expect(client.videos, edited);
    });
  }

  test('a changed account stops a 500 recovery before further requests',
      () async {
    client.failures[2] =
        InvidiousServiceError('Backend failed', statusCode: 500);
    client.onAppendError = () async {
      const other = Server(url: 'https://other.example', authToken: 'other');
      await db.upsertServer(other);
      await db.useServer(other);
    };
    await expectLater(copy().save(), throwsStateError);
    expect(client.accounts.length, 4); // Create, read, two insert attempts.
    expect(client.videos, ['first']);
  });

  for (final error in [
    InvidiousServiceError('Denied', statusCode: 403),
    InvidiousServiceError('Gateway unavailable',
        statusCode: 500, isGatewayResponse: true, errorCode: 'unavailable'),
    TimeoutException('Unconfirmed response'),
  ]) {
    test(
        'a failed append without a recoverable HTTP response requires explicit retry ($error)',
        () async {
      client.failures[2] = error;
      await expectLater(
          copy().save(), throwsA(isA<PlaylistTrackSaveFailure>()));
      expect(client.videos, ['first']);
      expect(client.appendAttempts, ['first', 'first']);
    });
  }

  test('does not append after another client edits the saved prefix', () async {
    client.loseAcknowledgment = true;
    await expectLater(copy().save(), throwsStateError);
    client.videos[0] = 'changed';
    await expectLater(copy().save(), throwsStateError);
    expect(client.videos, ['changed']);
    expect(client.creations, 1);
  });

  test('account changes stop further appends', () async {
    client.pending = Completer<void>();
    final operation = copy().save();
    final failed = expectLater(operation, throwsStateError);
    for (var i = 0; i < 30 && client.videos.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(client.videos, ['first']);
    const other = Server(
        url: 'https://playlist.example', id: 'other', authToken: 'other');
    await db.upsertServer(other);
    await db.useServer(other);
    client.pending!.complete();
    await failed;
    expect(client.videos, ['first']);
  });

  test('concurrent screens serialize a copy without duplicate appends',
      () async {
    client.pending = Completer<void>();
    final first = copy().save();
    for (var i = 0; i < 30 && client.videos.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = copy().save();
    await Future<void>.delayed(Duration.zero);
    expect(client.creations, 1);
    expect(client.videos, ['first']);
    client.pending!.complete();
    await Future.wait([first, second]);
    expect(client.creations, 1);
    expect(client.videos, ['first', 'first', 'second']);
  });

  test('incomplete metadata cannot create a partial server copy', () async {
    await expectLater(copy(source: playlist.copyWith(videoCount: 4)).save(),
        throwsStateError);
    expect(client.creations, 0);
  });

  testWidgets('a Music playlist rebuild preserves the in-flight server copy',
      (tester) async {
    final originalService = service;
    service = client;
    addTearDown(() => service = originalService);
    client.pending = Completer<void>();
    final tracks = [
      const MusicTrack(videoId: 'first', title: 'First'),
      const MusicTrack(videoId: 'second', title: 'Second'),
    ];
    Future<void> showPlaylist() => showCopy(
        tester,
        playlist.copyWith(
          videoCount: tracks.length,
          videos: tracks.map((track) => track.toVideo()).toList(),
        ));
    final save = find.byKey(const ValueKey('playlist-save-server'));
    await showPlaylist();
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    await showPlaylist();
    await tester
        .tap(find.widgetWithText(FilledButton, 'Save a copy on server'));
    await tester.pumpAndSettle();
    expect(client.videos, ['first']);

    await showPlaylist();
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(save).onPressed, isNull);
    client.pending!.complete();
    await tester.pumpAndSettle();
    expect(client.videos, ['first', 'second']);
    expect(find.descendant(of: save, matching: find.text('Saved on server')),
        findsOneWidget);

    await showPlaylist();
    expect(tester.widget<OutlinedButton>(save).onPressed, isNull);
    tracks.setAll(0, tracks.reversed.toList());
    await showPlaylist();
    expect(tester.widget<OutlinedButton>(save).onPressed, isNotNull);
  });

  testWidgets(
      'a persistent insert error names the track and resumes the same copy',
      (tester) async {
    final originalService = service;
    service = client;
    addTearDown(() => service = originalService);
    final error = InvidiousServiceError('Backend failed', statusCode: 500);
    client.failures.addAll({2: error, 3: error});
    await showCopy(
        tester,
        playlist.copyWith(videos: [
          playlist.videos.first,
          const Video(videoId: 'first', title: 'Encore'),
          playlist.videos.last,
        ]));
    await tester.pumpAndSettle();
    final save = find.byKey(const ValueKey('playlist-save-server'));
    Future<void> confirm(String label) async {
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, label));
      await tester.pumpAndSettle();
    }

    await confirm('Save a copy on server');
    expect(client.videos, ['first']);
    expect(find.textContaining('HTTP 500 while adding track 2 of 3 (“Encore”)'),
        findsOneWidget);
    expect(
        find.textContaining(
            'Resume to continue from the tracks already saved.'),
        findsOneWidget);
    await confirm('Resume server copy');
    expect(client.videos, ['first', 'first', 'second']);
    expect(client.creations, 1);
    expect(find.textContaining('HTTP 500'), findsNothing);
    expect(find.descendant(of: save, matching: find.text('Saved on server')),
        findsOneWidget);
  });

  test('ambiguous creation reports uncertainty without automatic retries',
      () async {
    client.failCreation = true;
    await expectLater(
        copy().save(), throwsA(isA<PlaylistCreationUnconfirmed>()));
    expect(client.creations, 1);
    expect(client.videos, isEmpty);
  });

  test('reopening after an unconfirmed create does not create a duplicate',
      () async {
    client.failCreation = true;
    final pending = <PlaylistCreationUnconfirmed>[];
    Future<void> attempt({PlaylistCreationUnconfirmed? confirmed}) async {
      try {
        await copy().save(confirmedReplacement: confirmed);
      } on PlaylistCreationUnconfirmed catch (error) {
        pending.add(error);
      }
    }

    await Future.wait([attempt(), attempt()]);
    expect(client.creations, 1);
    expect(pending, hasLength(2));
    expect(pending.last.id, pending.first.id);
    await attempt(confirmed: pending.first);
    expect(client.creations, 2);
    expect(pending.last.id, isNot(pending.first.id));
    client.failCreation = false;
    await attempt(confirmed: pending.first);
    expect(client.creations, 2);
    await copy().save(confirmedReplacement: pending.last);
    expect(client.creations, 3);
    expect(client.videos, ['first', 'first', 'second']);
  });

  test('a missing copy that reappears is resumed without creating another',
      () async {
    final id = await copy().save();
    client.missingDestinations.add(id);
    await expectLater(
        copy().save(),
        throwsA(isA<PlaylistCopyMissing>()
            .having((error) => error.id, 'destination', id)));
    client.missingDestinations.remove(id);
    expect(
        await copy().save(confirmedReplacement: PlaylistCopyMissing(id)), id);
    expect(client.creations, 1);
    expect(client.appendAttempts, ['first', 'first', 'second']);
  });

  testWidgets('a deleted server copy requires confirmation before replacement',
      (tester) async {
    final originalService = service;
    service = client;
    addTearDown(() => service = originalService);
    await showCopy(tester, playlist);
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('playlist-save-server'));
    Future<void> respond(String label) async {
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find
          .descendant(of: find.byType(AlertDialog), matching: find.text(label))
          .last);
      await tester.pumpAndSettle();
    }

    await respond('Save a copy on server');
    expect(client.creations, 1);
    await tester.pumpWidget(const SizedBox());
    client.missingDestinations.add('IVPcopy');
    await showCopy(tester, playlist);
    await tester.pumpAndSettle();
    await respond('Save a copy on server');
    expect(
        find.descendant(of: button, matching: find.text('Create a new copy')),
        findsOneWidget);
    await respond('Cancel');
    expect(client.creations, 1);
    await respond('Create a new copy');
    expect(client.creations, 2);
    expect(client.videos, ['first', 'first', 'second']);
    expect(find.descendant(of: button, matching: find.text('Saved on server')),
        findsOneWidget);
  });
}
