import 'dart:async';
import 'dart:convert';

import 'package:sembast/sembast.dart';

import '../../player/models/playback_session.dart';
import '../../network/gateway_session_bridge.dart';
import '../../settings/models/db/server.dart';
import '../../settings/models/db/settings.dart';
import '../../settings/models/errors/invidious_service_error.dart';
import '../../utils/interfaces/db.dart';
import '../../utils/sembast_sqflite_database.dart';
import '../models/db/progress.dart';

/// A local decision is separate from a position and from server history.
class WatchStatus {
  final bool? manualWatched;
  final bool localPlayback;
  final bool completed;
  final int revision;

  const WatchStatus(
      {this.manualWatched,
      this.localPlayback = false,
      this.completed = false,
      this.revision = 0});

  factory WatchStatus.fromJson(Map<String, dynamic>? json) => json == null
      ? const WatchStatus()
      : WatchStatus(
          manualWatched: json['manualWatched'] as bool?,
          localPlayback: json['localPlayback'] == true,
          completed: json['completed'] == true,
          revision: (json['revision'] as num?)?.toInt() ?? 0);

  bool isWatched(double progress, bool serverHistory) =>
      manualWatched ??
      (localPlayback || progress > 0
          ? completed || progress >= watchedProgressThreshold
          : serverHistory);

  Map<String, dynamic> toJson() => {
        'manualWatched': manualWatched,
        'localPlayback': localPlayback,
        'completed': completed,
        'revision': revision,
      };
}

class PendingWatchChange {
  final String accountId;
  final String videoId;
  final bool present;
  final int revision;
  const PendingWatchChange(
      this.accountId, this.videoId, this.present, this.revision);
  factory PendingWatchChange.fromJson(Map<String, dynamic> value) =>
      PendingWatchChange(
          value['accountId'] as String,
          value['videoId'] as String,
          value['present'] as bool,
          value['revision'] as int);
  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'videoId': videoId,
        'present': present,
        'revision': revision
      };
}

/// Every instance retains a fixed person, even when the app changes profiles.
class WatchRepository {
  final SembastSqfDb database;
  late final states =
      stringMapStoreFactory.store('watchState:${database.profileId}');
  late final memberships =
      stringMapStoreFactory.store('watchMembership:${database.profileId}');
  late final outbox =
      stringMapStoreFactory.store('watchOutbox:${database.profileId}');
  late final syncState =
      stringMapStoreFactory.store('watchSync:${database.profileId}');

  WatchRepository(SembastSqfDb database)
      : database = database.forProfile(database.profileId);

  static WatchRepository? forDatabase(IDbClient database) =>
      database is SembastSqfDb ? WatchRepository(database) : null;

  String _key(String accountId, String videoId) =>
      jsonEncode([accountId, videoId]);
  WatchStatus status(String videoId) =>
      WatchStatus.fromJson(states.record(videoId).getSync(database.db));

  bool isWatched(String videoId) {
    final remote = memberships.findFirstSync(database.db,
            finder: Finder(filter: Filter.equals('videoId', videoId))) !=
        null;
    return status(videoId)
        .isWatched(database.getVideoProgress(videoId), remote);
  }

  bool acceptsPlayback(String videoId, int revision) =>
      status(videoId).revision == revision;

  Future<void> saveSessionIfCurrent(
          String videoId, int revision, SettingsValue session) =>
      database.db.transaction((txn) async {
        final current =
            WatchStatus.fromJson(await states.record(videoId).get(txn));
        if (current.revision != revision) return;
        await database.settingsStore
            .record(session.name)
            .put(txn, session.toJson());
      });

  Future<int> beginPlayback(String videoId) async {
    final revision = await database.db.transaction((txn) async {
      final record = states.record(videoId);
      final old = WatchStatus.fromJson(await record.get(txn));
      final next = WatchStatus(
          manualWatched: old.manualWatched == false ? null : old.manualWatched,
          localPlayback: true,
          completed: old.completed ||
              database.getVideoProgress(videoId) >= watchedProgressThreshold,
          revision: old.revision + 1);
      await record.put(txn, next.toJson());
      return next.revision;
    });
    playbackHistoryRevision.value++;
    return revision;
  }

  Future<void> _enqueue(DatabaseClient txn, String accountId, String videoId,
      bool present) async {
    final record = outbox.record(_key(accountId, videoId));
    final sequence = syncState.record('sequence');
    final next = ((await sequence.get(txn))?['value'] as int? ?? 0) + 1;
    await sequence.put(txn, {'value': next});
    await record.put(
        txn, PendingWatchChange(accountId, videoId, present, next).toJson());
  }

  Future<void> mark(String videoId, bool watched, {Server? account}) async {
    if (account != null && account.profileId != database.profileId) {
      throw StateError('Watch account belongs to another profile');
    }
    await database.db.transaction((txn) async {
      final record = states.record(videoId);
      final old = WatchStatus.fromJson(await record.get(txn));
      await record.put(
          txn,
          WatchStatus(
                  manualWatched: watched,
                  localPlayback: old.localPlayback,
                  completed: watched ? old.completed : false,
                  revision: old.revision + (watched ? 0 : 1))
              .toJson());
      if (!watched) {
        await database.progressStore
            .record(videoId)
            .put(txn, Progress.named(progress: 0, videoId: videoId).toJson());
        final sessionRecord =
            database.settingsStore.record(playbackSessionSetting);
        final saved = await sessionRecord.get(txn);
        final session = PlaybackSession.decode(saved?['value'] as String?);
        if (session?.currentId == videoId) {
          final value = jsonDecode(session!.encode()) as Map<String, dynamic>;
          value['seconds'] = 0;
          await sessionRecord.put(
              txn,
              SettingsValue(playbackSessionSetting, jsonEncode(value))
                  .toJson());
        }
      }
      if (account != null && hasHistoryAccount(account)) {
        await _enqueue(txn, account.accountId, videoId, watched);
      }
    });
    playbackHistoryRevision.value++;
  }

  /// The revision rejects late events after a manual change or another session.
  Future<bool> recordPlayback(String videoId, double progress, int revision,
      {Server? account}) async {
    final result = await database.db.transaction((txn) async {
      final record = states.record(videoId);
      final old = WatchStatus.fromJson(await record.get(txn));
      if (old.revision != revision) return (accepted: false, changed: false);
      final completed = old.completed || progress >= watchedProgressThreshold;
      await database.progressStore.record(videoId).put(
          txn, Progress.named(progress: progress, videoId: videoId).toJson());
      await record.put(
          txn,
          WatchStatus(
                  manualWatched: old.manualWatched,
                  localPlayback: true,
                  completed: completed,
                  revision: old.revision)
              .toJson());
      if (progress > 0.1 &&
          account != null &&
          account.profileId == database.profileId &&
          hasHistoryAccount(account)) {
        final key = _key(account.accountId, videoId);
        final pending = await outbox.record(key).get(txn);
        if (await memberships.record(key).get(txn) == null && pending == null) {
          await _enqueue(txn, account.accountId, videoId, true);
        }
      }
      return (accepted: true, changed: old.completed != completed);
    });
    if (result.changed) playbackHistoryRevision.value++;
    return result.accepted;
  }

  List<PendingWatchChange> pending(String accountId) => outbox
      .findSync(database.db,
          finder: Finder(
              filter: Filter.equals('accountId', accountId),
              sortOrders: [SortOrder('revision')]))
      .map((row) => PendingWatchChange.fromJson(row.value))
      .toList();

  Future<void> acknowledge(PendingWatchChange change) async {
    await database.db.transaction((txn) async {
      final key = _key(change.accountId, change.videoId);
      final record = outbox.record(key);
      final current = await record.get(txn);
      // An old response cannot discard a newer opposite user action.
      if (current?['revision'] != change.revision) return;
      if (change.present) {
        await memberships.record(key).put(
            txn, {'accountId': change.accountId, 'videoId': change.videoId});
      } else {
        await memberships.record(key).delete(txn);
      }
      await record.delete(txn);
    });
    playbackHistoryRevision.value++;
  }

  Future<void> mergeRemote(String accountId, Set<String> ids,
      {required bool complete}) async {
    await database.db.transaction((txn) async {
      final changes = await outbox.find(txn,
          finder: Finder(filter: Filter.equals('accountId', accountId)));
      final pendingIds =
          changes.map((row) => row.value['videoId'] as String).toSet();
      if (complete) {
        final previous = await memberships.find(txn,
            finder: Finder(filter: Filter.equals('accountId', accountId)));
        for (final row in previous) {
          final id = row.value['videoId'] as String;
          if (!ids.contains(id) && !pendingIds.contains(id)) {
            await memberships.record(row.key).delete(txn);
          }
        }
      }
      for (final id in ids.difference(pendingIds)) {
        await memberships
            .record(_key(accountId, id))
            .put(txn, {'accountId': accountId, 'videoId': id});
      }
    });
    playbackHistoryRevision.value++;
  }

  Future<int> historyEditRevision() => database.db.transaction((txn) async =>
      (await syncState.record('sequence').get(txn))?['value'] as int? ?? 0);

  /// Server-only deletion preserves local watched choices and newer intent.
  Future<void> acknowledgeHistoryDeletion(String accountId, int revision,
      {String? videoId}) async {
    await database.db.transaction((txn) async {
      final filter = Filter.and([
        Filter.equals('accountId', accountId),
        if (videoId != null) Filter.equals('videoId', videoId),
      ]);
      final pending = await outbox.find(txn, finder: Finder(filter: filter));
      for (final row in pending) {
        if ((row.value['revision'] as int) <= revision) {
          await outbox.record(row.key).delete(txn);
        }
      }
      await memberships.delete(txn, finder: Finder(filter: filter));
      if (await outbox.findFirst(txn,
              finder: Finder(filter: Filter.equals('accountId', accountId))) ==
          null) {
        await syncState
            .record('account:$accountId')
            .put(txn, {'state': 'synced', 'attempts': 0});
      }
    });
    playbackHistoryRevision.value++;
  }

  Map<String, dynamic>? syncStatus(String accountId) =>
      syncState.record('account:$accountId').getSync(database.db);

  Future<void> setSyncStatus(String accountId, String state,
      {DateTime? retryAt, int attempts = 0}) async {
    await syncState.record('account:$accountId').put(database.db, {
      'state': state,
      'attempts': attempts,
      if (retryAt != null) 'retryAt': retryAt.millisecondsSinceEpoch,
    });
    playbackHistoryRevision.value++;
  }
}

bool hasHistoryAccount(Server server) =>
    (server.authToken?.isNotEmpty ?? false) ||
    (server.sidCookie?.isNotEmpty ?? false);

typedef ReadHistoryPage = Future<List<String>> Function(
    Server account, int page, int size);
typedef ChangeHistory = Future<void> Function(
    Server account, String videoId, bool present);

/// Work runs only while the app is open; pending intent survives process death.
class WatchHistorySync {
  final WatchRepository repository;
  final ReadHistoryPage readPage;
  final ChangeHistory changeHistory;
  final Future<bool> Function(Server account) accountIsCurrent;
  final DateTime Function() now;
  final Duration requestTimeout;
  final Map<String, Future<void>> _running = {};
  final Map<String, Server> _queuedFlushes = {};
  final Map<String, Future<void>> _historyEdits = {};
  final Map<String, Set<Future<void>>> _pendingWrites = {};

  WatchHistorySync(
      {required this.repository,
      required this.readPage,
      required this.changeHistory,
      required this.accountIsCurrent,
      this.requestTimeout = const Duration(seconds: 15),
      DateTime Function()? now})
      : now = now ?? DateTime.now;

  Future<void> run(Server account, {bool force = false, bool pull = true}) {
    if (account.profileId != repository.database.profileId ||
        !hasHistoryAccount(account)) {
      return Future.value();
    }
    final editing = _historyEdits[account.accountId];
    if (editing != null) {
      return _settled(editing)
          .then((_) => run(account, force: force, pull: pull));
    }
    final running = _running[account.accountId];
    if (running != null && force) {
      // Sign-in may finish while an older credential generation is in flight.
      return running.then((_) => run(account, force: true, pull: pull));
    }
    if (running != null) {
      if (repository.pending(account.accountId).isNotEmpty) {
        _queuedFlushes[account.accountId] = account;
      }
      return running;
    }
    return _running.putIfAbsent(account.accountId,
        () => _runWithQueuedFlushes(account, force: force, pull: pull));
  }

  static Future<void> _settled(Future<void>? future) async {
    try {
      await future;
    } catch (_) {
      // A previous request's failure must not poison a later explicit action.
    }
  }

  /// Fence sync before taking the revision snapshot, then serialize the remote
  /// edit after existing writes. An older offline mark cannot undo deletion.
  Future<void> deleteHistory(Server account,
      {String? videoId, required Future<void> Function() deleteRemote}) {
    final id = account.accountId;
    final precedingEdit = _historyEdits[id];
    final running = _running[id];
    final revision = repository.historyEditRevision();
    var succeeded = false;
    late final Future<void> operation;
    operation = (() async {
      final cutoff = await revision;
      await _settled(precedingEdit);
      await _settled(running);
      // A sync timeout does not cancel its underlying HTTP request. Fail the
      // edit rather than issue DELETE while an earlier POST can still finish.
      final writes = List<Future<void>>.of(_pendingWrites[id] ?? {});
      await Future.wait(writes.map(_settled)).timeout(requestTimeout);
      if (!await accountIsCurrent(account)) {
        throw StateError('Account changed before history deletion');
      }
      await deleteRemote();
      await repository.acknowledgeHistoryDeletion(id, cutoff, videoId: videoId);
      succeeded = true;
    })()
        .whenComplete(() {
      if (identical(_historyEdits[id], operation)) {
        _historyEdits.remove(id);
        if (succeeded && repository.pending(id).isNotEmpty) {
          unawaited(_settled(run(account, pull: false)));
        }
      }
    });
    _historyEdits[id] = operation;
    return operation;
  }

  Future<void> _write(Server account, PendingWatchChange change) {
    final id = account.accountId;
    final request = Future<void>.sync(
        () => changeHistory(account, change.videoId, change.present));
    final writes = _pendingWrites.putIfAbsent(id, () => {});
    writes.add(request);
    void finished() {
      writes.remove(request);
      if (writes.isEmpty && identical(_pendingWrites[id], writes)) {
        _pendingWrites.remove(id);
      }
    }

    unawaited(request.then<void>((_) => finished(),
        onError: (Object _, StackTrace __) => finished()));
    return request.timeout(requestTimeout);
  }

  Future<void> _runWithQueuedFlushes(Server account,
      {required bool force, required bool pull}) async {
    var remaining = 50;
    try {
      while (true) {
        remaining -= await _run(account,
            force: force, pull: pull, mutationLimit: remaining);
        final queued = _queuedFlushes.remove(account.accountId);
        if (queued == null || remaining == 0) return;
        // A mark can arrive during the pull or its final status write. Coalesce
        // those requests, sharing the original budget and honoring retry pauses.
        account = queued;
        force = false;
        pull = false;
      }
    } finally {
      _running.remove(account.accountId);
      _queuedFlushes.remove(account.accountId);
    }
  }

  Future<int> _run(Server account,
      {required bool force,
      required bool pull,
      required int mutationLimit}) async {
    final status = repository.syncStatus(account.accountId);
    final retryAt = status?['retryAt'] as int?;
    if (!force &&
        (status?['state'] == 'signInRequired' ||
            status?['state'] == 'failed' ||
            (retryAt != null && retryAt > now().millisecondsSinceEpoch))) {
      return 0;
    }
    if (_historyEdits.containsKey(account.accountId) ||
        !await accountIsCurrent(account)) {
      return 0;
    }
    var sent = 0;
    try {
      // Bound a run, including a queue accumulated during a long offline period.
      while (sent < mutationLimit) {
        if (_historyEdits.containsKey(account.accountId)) return sent;
        final pending = repository.pending(account.accountId).firstOrNull;
        if (pending == null) break;
        if (!await accountIsCurrent(account)) return sent;
        sent++;
        await _write(account, pending);
        if (!await accountIsCurrent(account)) return sent;
        await repository.acknowledge(pending);
      }
      if (pull) {
        const size = 200;
        final ids = <String>{};
        var complete = false;
        try {
          for (var page = 1; page <= 10; page++) {
            if (_historyEdits.containsKey(account.accountId)) return sent;
            if (!await accountIsCurrent(account)) return sent;
            final values = await readPage(account, page, size)
                .timeout(const Duration(seconds: 15));
            ids.addAll(values);
            if (values.length < size) {
              complete = true;
              break;
            }
          }
        } catch (_) {
          if (ids.isNotEmpty && await accountIsCurrent(account)) {
            await repository.mergeRemote(account.accountId, ids,
                complete: false);
          }
          rethrow;
        }
        if (_historyEdits.containsKey(account.accountId) ||
            !await accountIsCurrent(account)) {
          return sent;
        }
        await repository.mergeRemote(account.accountId, ids,
            complete: complete);
      }
      await repository.setSyncStatus(account.accountId,
          repository.pending(account.accountId).isEmpty ? 'synced' : 'pending');
    } catch (error) {
      if (!await accountIsCurrent(account)) return sent;
      final auth = error is GatewayAuthenticationRequired ||
          error is InvidiousServiceError &&
              (error.statusCode == 401 ||
                  error.statusCode == 403 ||
                  error.responseWasHtml);
      final permanent = error is InvidiousServiceError &&
          !auth &&
          error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500 &&
          error.statusCode != 408 &&
          error.statusCode != 429;
      final attempts = ((status?['attempts'] as int?) ?? 0) + 1;
      final delay = error is InvidiousServiceError && error.retryAfter != null
          ? error.retryAfter!
          : Duration(seconds: (5 * (1 << attempts.clamp(0, 8))).clamp(10, 900));
      await repository.setSyncStatus(
          account.accountId,
          auth
              ? 'signInRequired'
              : permanent
                  ? 'failed'
                  : 'pending',
          attempts: attempts,
          retryAt: auth || permanent ? null : now().add(delay));
    }
    return sent;
  }
}
