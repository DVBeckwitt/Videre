import 'dart:async';

import 'package:clipious/player/models/playback_session.dart';
import 'package:clipious/network/gateway_session_bridge.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/db/settings.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/db/progress.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/services/watch_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const account = Server(
    url: 'https://instance.example',
    id: 'account-a',
    authToken: 'test-token-a',
  );
  const otherAccount = Server(
    url: 'https://instance.example',
    id: 'account-b',
    authToken: 'test-token-b',
  );
  late SembastSqfDb database;
  late WatchRepository repository;

  setUp(() async {
    database = await SembastSqfDb.createInMemory();
    repository = WatchRepository(database);
  });

  tearDown(() async => database.close());

  group('local watched decisions', () {
    test('manual watched preserves exact time and unwatched clears it',
        () async {
      final revision = await repository.beginPlayback('video');
      await repository.recordPlayback('video', 1, revision,
          positionSeconds: 95, durationSeconds: 100);
      await repository.mark('video', true);
      expect(database.getVideoPlaybackProgress('video').positionSeconds, 95);
      await repository.mark('video', false);
      expect(database.getVideoPlaybackProgress('video').resumePosition(),
          Duration.zero);
      expect(
          await repository.recordPlayback('video', 1, revision,
              positionSeconds: 96, durationSeconds: 100),
          isFalse);
      expect(
          database.getVideoPlaybackProgress('video').positionSeconds, isNull);
    });

    test('mark unwatched resets a duplicated current queue occurrence',
        () async {
      await database.saveSetting(SettingsValue(
          playbackSessionSetting,
          PlaybackSession(
            videos: [
              Video(videoId: 'video'),
              Video(videoId: 'video', queueEntryId: 'video#1'),
            ],
            currentId: 'video#1',
            seconds: 80,
            played: const ['video'],
          ).encode()));
      await repository.mark('video', false);
      final saved = PlaybackSession.decode(
          database.getSettings(playbackSessionSetting)?.value)!;
      expect(saved.seconds, 0);
      expect(saved.currentId, 'video#1');
      expect(saved.played, ['video']);
    });

    test('mark watched preserves a real partial resume position', () async {
      await database.saveProgress(Progress(0.4, 'partial'));
      await repository.mark('partial', true, account: account);

      expect(repository.isWatched('partial'), isTrue);
      expect(database.getVideoProgress('partial'), 0.4);
      expect(repository.status('partial').completed, isFalse);
      expect(repository.pending(account.accountId).single.present, isTrue);
    });

    test('mark watched lets the current session keep its real resume position',
        () async {
      final session = await repository.beginPlayback('playing');
      await repository.recordPlayback('playing', 0.2, session);
      await repository.mark('playing', true);
      expect(await repository.recordPlayback('playing', 0.4, session), isTrue);
      expect(database.getVideoProgress('playing'), 0.4);
      expect(repository.isWatched('playing'), isTrue);
    });

    test('mark unwatched resets only the affected resume and keeps queue',
        () async {
      await database.saveProgress(Progress(1, 'video'));
      await database.saveProgress(Progress(0.6, 'another'));
      await database.saveSetting(SettingsValue(
          playbackSessionSetting,
          PlaybackSession(
            videos: [Video(videoId: 'video'), Video(videoId: 'next')],
            currentId: 'video',
            seconds: 80,
            next: const ['next'],
          ).encode()));

      await repository.mark('video', false, account: account);
      final saved = PlaybackSession.decode(
          database.getSettings(playbackSessionSetting)?.value)!;

      expect(repository.isWatched('video'), isFalse);
      expect(database.getVideoProgress('video'), 0);
      expect(database.getVideoProgress('another'), 0.6);
      expect(saved.seconds, 0);
      expect(saved.currentId, 'video');
      expect(saved.videos.map((video) => video.videoId), ['video', 'next']);
      expect(saved.next, ['next']);
      expect(repository.pending(account.accountId).single.present, isFalse);
    });

    test('a server pull cannot undo an explicit unwatched decision', () async {
      await repository.mergeRemote(account.accountId, {'video'},
          complete: true);
      expect(repository.isWatched('video'), isTrue);
      await repository.mark('video', false, account: account);
      final deletion = repository.pending(account.accountId).single;
      await repository.acknowledge(deletion);
      await repository.mergeRemote(account.accountId, {'video'},
          complete: true);

      expect(repository.isWatched('video'), isFalse);
      expect(repository.status('video').manualWatched, isFalse);
      expect(database.getVideoProgress('video'), 0);
    });

    test('late playback cannot reverse manual unwatched; a new session can',
        () async {
      final oldSession = await repository.beginPlayback('video');
      await repository.recordPlayback('video', 0.95, oldSession,
          account: account);
      await repository.mark('video', false, account: account);

      expect(
          await repository.recordPlayback('video', 1, oldSession,
              account: account),
          isFalse);
      expect(repository.acceptsPlayback('video', oldSession), isFalse);
      expect(repository.isWatched('video'), isFalse);
      expect(database.getVideoProgress('video'), 0);

      final newSession = await repository.beginPlayback('video');
      expect(repository.status('video').manualWatched, isNull);
      expect(
          await repository.recordPlayback('video', 0.95, newSession,
              account: account),
          isTrue);
      expect(repository.isWatched('video'), isTrue);
    });

    test('another playback session rejects events from the first', () async {
      final first = await repository.beginPlayback('video');
      final second = await repository.beginPlayback('video');
      await repository.recordPlayback('video', 0.5, second);

      expect(await repository.recordPlayback('video', 0.9, first), isFalse);
      expect(database.getVideoProgress('video'), 0.5);
      expect(repository.isWatched('video'), isFalse);
    });

    test('server membership never turns known partial playback into completion',
        () async {
      await database.saveProgress(Progress(0.2, 'partial'));
      await repository.mergeRemote(account.accountId, {'partial', 'remote'},
          complete: true);

      expect(repository.isWatched('partial'), isFalse);
      expect(database.getVideoProgress('partial'), 0.2);
      expect(repository.isWatched('remote'), isTrue);
      expect(database.getVideoProgress('remote'), 0);
    });

    test('completion survives replay until explicitly reset', () async {
      final first = await repository.beginPlayback('video');
      await repository.recordPlayback('video', 0.95, first);
      final replay = await repository.beginPlayback('video');
      await repository.recordPlayback('video', 0.1, replay);

      expect(database.getVideoProgress('video'), 0.1);
      expect(repository.isWatched('video'), isTrue);
      await repository.mark('video', false);
      expect(repository.isWatched('video'), isFalse);
    });

    test('guest marking stays local and rejects another person account',
        () async {
      await repository.mark('guest-video', true);
      expect(repository.isWatched('guest-video'), isTrue);
      expect(repository.pending(account.accountId), isEmpty);
      await expectLater(
          repository.mark('other-person', true,
              account: account.copyWith(profileId: 'other-profile')),
          throwsStateError);
      expect(repository.isWatched('other-person'), isFalse);
    });
  });

  group('durable scoped desired state', () {
    test('a new repository retains pending intent and coalesces rapid toggles',
        () async {
      await repository.mark('video', true, account: account);
      final firstRevision =
          repository.pending(account.accountId).single.revision;
      await repository.mark('video', false, account: account);
      await repository.mark('video', true, account: account);

      final restarted = WatchRepository(database);
      final pending = restarted.pending(account.accountId);
      expect(pending, hasLength(1));
      expect(pending.single.present, isTrue);
      expect(pending.single.revision, greaterThan(firstRevision));
      expect(restarted.isWatched('video'), isTrue);
    });

    test('duplicate and reordered acknowledgements preserve newer intent',
        () async {
      await repository.mark('video', true, account: account);
      final oldWrite = repository.pending(account.accountId).single;
      await repository.mark('video', false, account: account);
      final newWrite = repository.pending(account.accountId).single;
      await repository.acknowledge(oldWrite);

      expect(repository.pending(account.accountId).single.revision,
          newWrite.revision);
      expect(repository.isWatched('video'), isFalse);
      await repository.acknowledge(newWrite);
      await repository.acknowledge(oldWrite);
      await repository.acknowledge(newWrite);
      expect(repository.pending(account.accountId), isEmpty);
      expect(repository.isWatched('video'), isFalse);
    });

    test('accounts at one URL retain separate queued mutations', () async {
      await repository.mark('video', true, account: account);
      await repository.mark('video', false, account: otherAccount);

      expect(repository.pending(account.accountId).single.present, isTrue);
      expect(
          repository.pending(otherAccount.accountId).single.present, isFalse);
      await repository
          .acknowledge(repository.pending(account.accountId).single);
      expect(repository.pending(account.accountId), isEmpty);
      expect(repository.pending(otherAccount.accountId), hasLength(1));
      expect(repository.isWatched('video'), isFalse);
    });

    test('captured repository remains with its person after profile switch',
        () async {
      final other = await database.createProfile('Other person');
      final otherRepository = WatchRepository(database.forProfile(other.id));
      final otherPersonAccount = account.copyWith(profileId: other.id);
      await repository.mark('video', true, account: account);
      await database.useProfile(other.id);
      await repository.mark('still-default', true, account: account);
      await otherRepository.mark('other-only', true,
          account: otherPersonAccount);

      expect(repository.database.profileId, 'default');
      expect(otherRepository.isWatched('video'), isFalse);
      expect(otherRepository.isWatched('still-default'), isFalse);
      expect(repository.isWatched('other-only'), isFalse);
      expect(
          repository.pending(account.accountId).map((entry) => entry.videoId),
          ['video', 'still-default']);
      expect(otherRepository.pending(account.accountId).single.videoId,
          'other-only');
    });

    test('partial pulls add memberships; only complete pulls remove absences',
        () async {
      await repository.mergeRemote(account.accountId, {'older'},
          complete: true);
      await repository.mergeRemote(otherAccount.accountId, {'other-account'},
          complete: true);
      await repository.mergeRemote(account.accountId, {'recent'},
          complete: false);
      expect(repository.isWatched('older'), isTrue);
      expect(repository.isWatched('recent'), isTrue);

      await repository.mergeRemote(account.accountId, {'recent'},
          complete: true);
      expect(repository.isWatched('older'), isFalse);
      expect(repository.isWatched('recent'), isTrue);
      expect(repository.isWatched('other-account'), isTrue);
    });

    test(
        'playback queues one history registration without uploading legacy data',
        () async {
      await database.saveProgress(Progress(1, 'legacy'));
      final session = await repository.beginPlayback('new');
      await repository.recordPlayback('new', 0.05, session, account: account);
      expect(repository.pending(account.accountId), isEmpty);
      await repository.recordPlayback('new', 0.2, session, account: account);
      await repository.recordPlayback('new', 0.3, session, account: account);
      expect(repository.pending(account.accountId), hasLength(1));
      final registration = repository.pending(account.accountId).single;
      expect(registration.videoId, 'new');
      await repository.acknowledge(registration);
      await repository.recordPlayback('new', 0.4, session, account: account);
      expect(repository.pending(account.accountId), isEmpty);
    });
  });

  group('bounded account sync', () {
    for (final (label, failure, expectedStatus) in <(String, Object?, String)>[
      ('successful', null, 'synced'),
      (
        'authentication failure',
        const GatewayAuthenticationRequired(),
        'signInRequired'
      ),
      ('transient failure', TimeoutException('offline fixture'), 'pending'),
    ]) {
      test('a mark during a $label pull keeps its follow-up flush', () async {
        final entered = Completer<void>();
        final response = Completer<List<String>>();
        final sent = <String>[];
        final coordinator = WatchHistorySync(
          repository: repository,
          accountIsCurrent: (_) async => true,
          readPage: (_, page, size) async {
            entered.complete();
            return response.future;
          },
          changeHistory: (_, id, present) async => sent.add(id),
        );

        final pulling = coordinator.run(account);
        await entered.future;
        await repository.mark('new-mark', true, account: account);
        final flushing = coordinator.run(account, pull: false);
        expect(identical(pulling, flushing), isTrue);
        if (failure == null) {
          response.complete([]);
        } else {
          response.completeError(failure);
        }
        await Future.wait([pulling, flushing]);

        expect(
            repository.syncStatus(account.accountId)?['state'], expectedStatus);
        if (failure == null) {
          expect(sent, ['new-mark']);
          expect(repository.pending(account.accountId), isEmpty);
        } else {
          expect(sent, isEmpty);
          expect(repository.pending(account.accountId), hasLength(1));
          // The queued request cannot bypass an auth pause or retry deadline.
          await coordinator.run(account, pull: false);
          expect(sent, isEmpty);
        }
      });
    }

    test('a follow-up flush shares the original fifty-mutation budget',
        () async {
      for (var i = 0; i < 49; i++) {
        await repository.mark('earlier-$i', true, account: account);
      }
      final entered = Completer<void>();
      final response = Completer<List<String>>();
      final sent = <String>[];
      var reads = 0;
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, page, size) async {
          reads++;
          entered.complete();
          return response.future;
        },
        changeHistory: (_, id, present) async => sent.add(id),
      );

      final active = coordinator.run(account);
      await entered.future;
      await repository.mark('new-first', true, account: account);
      final first = coordinator.run(account, pull: false);
      await repository.mark('new-second', true, account: account);
      final second = coordinator.run(account, pull: false);
      response.complete([]);
      await Future.wait([active, first, second]);

      expect(reads, 1);
      expect(sent, hasLength(50));
      expect(sent.last, 'new-first');
      expect(
          repository.pending(account.accountId).single.videoId, 'new-second');
      expect(repository.syncStatus(account.accountId)?['state'], 'pending');
    });

    test(
        'a toggle during an in-flight write sends the newest intent in the same run',
        () async {
      await repository.mark('video', true, account: account);
      final sent = <bool>[];
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      final coordinator = WatchHistorySync(
          repository: repository,
          accountIsCurrent: (_) async => true,
          readPage: (_, page, size) async => [],
          changeHistory: (_, id, present) async {
            sent.add(present);
            if (sent.length == 1) {
              firstEntered.complete();
              await releaseFirst.future;
            }
          });
      final active = coordinator.run(account, pull: false);
      await firstEntered.future;
      await repository.mark('video', false, account: account);
      releaseFirst.complete();
      await active;
      expect(sent, [true, false]);
      expect(repository.pending(account.accountId), isEmpty);
      expect(repository.isWatched('video'), isFalse);
    });

    test('transient failure survives coordinator restart and respects backoff',
        () async {
      await repository.mark('video', true, account: account);
      var clock = DateTime.utc(2026, 1, 1);
      var calls = 0;
      var offline = true;
      WatchHistorySync coordinator(WatchRepository storage) => WatchHistorySync(
            repository: storage,
            now: () => clock,
            accountIsCurrent: (_) async => true,
            readPage: (_, page, size) async => [],
            changeHistory: (_, id, present) async {
              calls++;
              if (offline) throw TimeoutException('offline fixture');
            },
          );

      await coordinator(repository).run(account, pull: false);
      expect(repository.pending(account.accountId), hasLength(1));
      expect(repository.syncStatus(account.accountId)?['state'], 'pending');
      final restarted = coordinator(WatchRepository(database));
      offline = false;
      await restarted.run(account, pull: false);
      expect(calls, 1);
      clock = clock.add(const Duration(minutes: 20));
      await restarted.run(account, pull: false);
      expect(calls, 2);
      expect(repository.pending(account.accountId), isEmpty);
      expect(repository.syncStatus(account.accountId)?['state'], 'synced');
    });

    test('an authentication challenge pauses retries until explicit retry',
        () async {
      await repository.mark('video', true, account: account);
      var signedIn = false;
      var calls = 0;
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, page, size) async => [],
        changeHistory: (_, id, present) async {
          calls++;
          if (!signedIn) {
            throw InvidiousServiceError('gateway sign-in',
                statusCode: 200, responseWasHtml: true);
          }
        },
      );

      await coordinator.run(account, pull: false);
      expect(
          repository.syncStatus(account.accountId)?['state'], 'signInRequired');
      signedIn = true;
      await coordinator.run(account, pull: false);
      expect(calls, 1);
      expect(repository.pending(account.accountId), hasLength(1));
      await coordinator.run(account, force: true, pull: false);
      expect(calls, 2);
      expect(repository.pending(account.accountId), isEmpty);
    });

    test('native gateway expiry pauses writes without losing offline intent',
        () async {
      await repository.mark('video', false, account: account);
      final coordinator = WatchHistorySync(
          repository: repository,
          accountIsCurrent: (_) async => true,
          readPage: (_, page, size) async => [],
          changeHistory: (_, id, present) async =>
              throw const GatewayAuthenticationRequired());
      await coordinator.run(account, pull: false);
      expect(
          repository.syncStatus(account.accountId)?['state'], 'signInRequired');
      expect(repository.pending(account.accountId).single.present, isFalse);
    });

    test(
        'a late response from invalidated credentials cannot acknowledge intent',
        () async {
      await repository.mark('video', true, account: account);
      final entered = Completer<void>();
      final response = Completer<void>();
      var valid = true;
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => valid,
        readPage: (_, page, size) async => [],
        changeHistory: (captured, id, present) async {
          expect(captured, account);
          entered.complete();
          await response.future;
        },
      );

      final sync = coordinator.run(account, pull: false);
      await entered.future;
      valid = false;
      response.complete();
      await sync;
      expect(repository.pending(account.accountId), hasLength(1));
    });

    test('concurrent triggers share one account run', () async {
      final entered = Completer<void>();
      final response = Completer<List<String>>();
      var reads = 0;
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, page, size) async {
          reads++;
          entered.complete();
          return response.future;
        },
        changeHistory: (_, id, present) async {},
      );

      final first = coordinator.run(account);
      await entered.future;
      final second = coordinator.run(account);
      expect(identical(first, second), isTrue);
      response.complete(['remote']);
      await Future.wait([first, second]);
      expect(reads, 1);
      expect(repository.isWatched('remote'), isTrue);
    });

    test('a bounded incomplete pull does not delete older memberships',
        () async {
      await repository.mergeRemote(account.accountId, {'older'},
          complete: true);
      final pages = <int>[];
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, page, size) async {
          pages.add(page);
          return List.generate(size, (index) => 'page-$page-$index');
        },
        changeHistory: (_, id, present) async {},
      );

      await coordinator.run(account);
      expect(pages, List.generate(10, (index) => index + 1));
      expect(repository.isWatched('older'), isTrue);
      expect(repository.isWatched('page-10-199'), isTrue);
      expect(database.getAllProgress(), isEmpty);
    });

    test('failed later page leaves previous memberships intact', () async {
      await repository.mergeRemote(account.accountId, {'older'},
          complete: true);
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, page, size) async {
          if (page > 1) throw TimeoutException('interrupted pull');
          return List.generate(size, (index) => 'recent-$index');
        },
        changeHistory: (_, id, present) async {},
      );

      await coordinator.run(account);
      expect(repository.isWatched('older'), isTrue);
      expect(repository.isWatched('recent-199'), isTrue);
      expect(repository.syncStatus(account.accountId)?['state'], 'pending');
    });

    test('a large offline outbox is processed within the mutation budget',
        () async {
      for (var i = 0; i < 52; i++) {
        await repository.mark('video-$i', true, account: account);
      }
      final sent = <String>[];
      final coordinator = WatchHistorySync(
        repository: repository,
        accountIsCurrent: (_) async => true,
        readPage: (_, page, size) async => [],
        changeHistory: (_, id, present) async => sent.add(id),
      );

      await coordinator.run(account, pull: false);
      expect(sent, hasLength(50));
      expect(repository.pending(account.accountId), hasLength(2));
      expect(repository.syncStatus(account.accountId)?['state'], 'pending');
      await coordinator.run(account, pull: false);
      expect(sent.toSet(), hasLength(52));
      expect(repository.pending(account.accountId), isEmpty);
    });
  });
}
