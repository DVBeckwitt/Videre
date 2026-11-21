import 'dart:async';

import 'package:clipious/network/media_companion.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';

import '../support/media_companion_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const account = Server(url: 'https://watch.example', id: 'first');
  const origin = 'https://media.example';
  const other = 'https://second.example:8443';

  test('only explicit public HTTPS DNS origins are eligible', () {
    expect(parseMediaCompanionOrigin(' HTTPS://MEDIA.example:443/ '), origin);
    expect(parseMediaCompanionOrigin(other), other);
    for (final invalid in [
      'media.example',
      'http://media.example',
      'https://*.example',
      'https://a..example',
      'https://media.example.',
      'https://media.example/path',
      'https://media.example/?',
      'https://media.example/#',
      'https://@media.example',
      'https://user:pass@media.example',
      'https://media.example:65536',
      'https://media.example:0',
      'https://127.0.0.1',
      'https://127.1',
      'https://0177.0.0.1',
      'https://0x7f.0x1',
      'https://[::1]',
      'https://x.localhost',
      'https://x.onion',
      'https://host.home.arpa',
      'https://r2.googlevideo.com',
      'https://www.youtube.co.uk',
    ]) {
      expect(parseMediaCompanionOrigin(invalid), isNull, reason: invalid);
    }
  });

  test('approved destinations match an exact origin and get no account headers',
      () {
    final saved = account.copyWith(
        mediaCompanionOrigins: [other, origin],
        customHeaders: {'x-private': 'instance-only'});
    expect(allowsMediaCompanion(saved, Uri.parse('$origin/media?signature=x')),
        isTrue);
    expect(saved.headersForUrl('$origin/media'), isNull);
    for (final invalid in [
      'https://cdn.media.example',
      'http://media.example',
      'https://media.example:8443',
      'https://you@media.example',
      'https://evil.example'
    ]) {
      expect(allowsMediaCompanion(saved, Uri.parse(invalid)), isFalse,
          reason: invalid);
    }
    expect(mediaCompanionContext(saved), {
      'origin': account.url,
      'instanceBase': account.url,
      'origins': [origin, other],
      'gatewayContext': GatewayRequestContext.forAccount(
              account.profileId, account.accountId, account.url)!
          .encoded,
    });
    expect(mediaCompanionContext(account), isNull);
    expect(
        allowsMediaCompanion(saved.copyWith(profileId: ''), Uri.parse(origin)),
        isFalse);
    expect(allowsMediaCompanion(saved.copyWith(id: ''), Uri.parse(origin)),
        isFalse);
    expect(mediaCompanionContext(saved.copyWith(url: 'http://watch.example')),
        isNull);
    expect(mediaCompanionContext(saved.copyWith(url: 'https://watch.onion')),
        isNull);
    expect(
        Server.fromJson({'url': account.url}).mediaCompanionOrigins, isEmpty);
    expect(trustedMediaCompanionOrigins(Server.fromJson(saved.toJson())),
        {origin, other});
  });

  test('account updates and backups cannot inject or restore grants', () async {
    mockMediaCompanionTransport();
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    // Only the dedicated local settings operation can grant access.
    await db.upsertServer(account.copyWith(mediaCompanionOrigins: [origin]));
    expect(trustedMediaCompanionOrigins(db.getAccount(account.accountId)!),
        isEmpty);
    final granted =
        await db.setMediaCompanionOrigin(account, origin, enabled: true);
    await db.upsertServer(account.copyWith(name: 'Renamed'));
    expect(trustedMediaCompanionOrigins(db.getAccount(account.accountId)!),
        {origin});
    // A sibling inherits the local decision, ignoring the claimed grants.
    await db.upsertServer(
        granted.copyWith(id: 'second', mediaCompanionOrigins: [other]));
    expect(db.getAccount('second')!.mediaCompanionOrigins, [origin]);
    expect((await db.exportBackup()).encode(), isNot(contains(origin)));

    await db.setMediaCompanionOrigin(account, origin, enabled: false);
    await db.upsertServer(granted);
    expect(db.getAccount(account.accountId)!.mediaCompanionOrigins, isEmpty);
    await db.setMediaCompanionOrigin(account, origin, enabled: true);
    await db.upsertServer(granted.copyWith(url: 'https://replacement.example'));
    expect(db.getAccount(account.accountId)!.mediaCompanionOrigins, isEmpty);
    await expectLater(
        db.setMediaCompanionOrigin(account, origin, enabled: true),
        throwsStateError);
  });

  test('sample approvals merge all selected hosts in one transaction',
      () async {
    mockMediaCompanionTransport();
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    await db.upsertServer(account);
    await db.setMediaCompanionOrigin(account, origin, enabled: true);
    await expectLater(
        db.setMediaCompanionOrigins(account, {other, 'http://invalid.example'},
            enabled: true),
        throwsFormatException);
    expect(db.mediaCompanionDecision(account), {origin});
    const third = 'https://third.example';
    await db.setMediaCompanionOrigins(account, {other, third}, enabled: true);
    expect(db.mediaCompanionDecision(account), {origin, other, third});
  });

  test('queued consent edits merge on their latest account row', () async {
    mockMediaCompanionTransport();
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    await db.upsertServer(account);
    await Future.wait([
      db.setMediaCompanionOrigin(account, origin, enabled: true),
      db.setMediaCompanionOrigin(account, other, enabled: true),
    ]);
    expect(trustedMediaCompanionOrigins(db.getAccount(account.accountId)!),
        {origin, other});
    final second = await db.createProfile('Other person');
    final owner = db.forProfile(second.id);
    await owner.upsertServer(account.copyWith(profileId: second.id));
    expect(owner.getAccount(account.accountId)!.mediaCompanionOrigins, isEmpty);
    expect(() => owner.setMediaCompanionOrigin(account, origin, enabled: true),
        throwsStateError);
  });

  test('revocation fences the exact account before completing the edit',
      () async {
    final platform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = platform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final calls = <Map>[];
    final waiting = Completer<void>();
    final release = Completer<void>();
    final firstKey = GatewayRequestContext.forAccount(
            account.profileId, account.accountId, account.url)!
        .encoded;
    mockMediaCompanionTransport(onSetOrigins: (call) async {
      final args = call.arguments as Map;
      calls.add(args);
      if (!waiting.isCompleted && (args['origins'] as List).isEmpty) {
        waiting.complete();
        await release.future;
      }
    });
    final second =
        account.copyWith(id: 'second', url: 'https://another.example');
    await db.upsertServer(account);
    await db.upsertServer(second);
    await db.setMediaCompanionOrigin(account, origin, enabled: true);
    await db.setMediaCompanionOrigin(second, other, enabled: true);
    var completed = false;
    final removal = db
        .setMediaCompanionOrigin(account, origin, enabled: false)
        .then((_) => completed = true);
    await waiting.future;
    final queued = db.setMediaCompanionOrigin(account, other, enabled: true);
    expect(completed, isFalse);
    expect(calls.last['gatewayContext'], firstKey);
    expect(calls.last['origin'], account.url);
    expect(calls.last['origins'], isEmpty);
    expect(calls, hasLength(3));
    release.complete();
    await removal;
    await queued;
    expect(calls.last['gatewayContext'], firstKey);
    expect(calls.last['origins'], [other]);
    expect(db.getAccount(second.accountId)!.mediaCompanionOrigins, [other]);

    // Endpoint edits and deletion also retire delayed native sources.
    await db.upsertServer(account.copyWith(url: 'https://changed.example'));
    expect(calls.last['gatewayContext'], firstKey);
    expect(calls.last['origins'], isEmpty);
    await db.deleteServerById(second);
    expect(calls.last['gatewayContext'], isNot(firstKey));
    expect(calls.last['origins'], isEmpty);
  });

  test('Android transport failures roll back a grant', () async {
    final platform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = platform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    mockMediaCompanionTransport(onSetOrigins: (_) async {
      throw PlatformException(code: 'UNAVAILABLE');
    });
    await db.upsertServer(account);
    await expectLater(
        db.setMediaCompanionOrigin(account, origin, enabled: true),
        throwsA(isA<PlatformException>()));
    expect(db.getAccount(account.accountId)!.mediaCompanionOrigins, isEmpty);
  });

  test(
      'setup creates its grant and correct initial selection as one account operation',
      () async {
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    mockMediaCompanionTransport();
    final setup = account.copyWith(mediaCompanionOrigins: [origin]);
    final first = await db.addAccountWithMediaCompanions(setup,
        isCurrent: () => true, setupDecision: {origin});
    expect(first!.inUse, isTrue);
    expect(db.getAccount(account.accountId), first);
    await expectLater(
        db.addAccountWithMediaCompanions(
            setup.copyWith(mediaCompanionOrigins: [other]),
            isCurrent: () => true,
            setupDecision: {other}),
        throwsStateError);
    expect(db.getAccount(account.accountId)!.mediaCompanionOrigins, [origin]);
    final second = await db.addAccountWithMediaCompanions(
        setup.copyWith(id: 'next', mediaCompanionOrigins: [other]),
        isCurrent: () => true,
        setupDecision: {other});
    expect(second!.inUse, isFalse);
    expect(db.getAccount(second.accountId)!.mediaCompanionOrigins, [origin]);
    expect((await db.getCurrentlySelectedServer()).accountId, first.accountId);
  });

  test('an abandoned setup clears its native grant and leaves no new account',
      () async {
    final platform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = platform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final calls = <List>[];
    var current = true;
    mockMediaCompanionTransport(onSetOrigins: (call) async {
      calls.add((call.arguments as Map)['origins'] as List);
      current = false;
    });
    final saved = await db.addAccountWithMediaCompanions(
        account.copyWith(mediaCompanionOrigins: [origin]),
        isCurrent: () => current,
        setupDecision: {origin});
    expect(saved, isNull);
    expect(calls, [
      [origin],
      isEmpty
    ]);
    expect(await db.getServers(), isEmpty);
    expect(db.mediaCompanionDecision(account), isNull);
  });

  test('manual changes reach each matching account and native gateway scope',
      () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final calls = <MethodCall>[];
    mockMediaCompanionTransport(onSetOrigins: (call) async => calls.add(call));
    final first = account.copyWith(
        url: 'https://watch.example/videos/',
        authToken: 'first-token',
        inUse: true);
    final sibling = account.copyWith(
        id: 'sibling',
        url: 'https://watch.example/videos',
        sidCookie: 'sibling-cookie');
    final otherPath = account.copyWith(id: 'other-path');
    final otherPort = account.copyWith(
        id: 'other-port', url: 'https://watch.example:8443/videos');
    final profile = await db.createProfile('Someone else');
    final otherOwner = db.forProfile(profile.id);
    final otherPerson = sibling.copyWith(profileId: profile.id);
    for (final candidate in [first, sibling, otherPath, otherPort]) {
      await db.upsertServer(candidate);
    }
    await otherOwner.upsertServer(otherPerson);

    for (final enabled in [true, false]) {
      calls.clear();
      await db.setMediaCompanionOrigin(first, origin, enabled: enabled);
      final expected = enabled ? [origin] : <String>[];
      final savedFirst = db.getAccount(first.accountId)!;
      final savedSibling = db.getAccount(sibling.accountId)!;
      expect(savedFirst.mediaCompanionOrigins, expected);
      expect(savedSibling.mediaCompanionOrigins, expected);
      expect(savedFirst.authToken, 'first-token');
      expect(savedFirst.sidCookie, isNull);
      expect(savedSibling.sidCookie, 'sibling-cookie');
      expect(savedSibling.authToken, isNull);
      expect(
          (await db.getCurrentlySelectedServer()).accountId, first.accountId);
      expect(db.mediaCompanionDecision(sibling), expected.toSet());
      for (final unrelated in [otherPath, otherPort]) {
        expect(db.mediaCompanionDecision(unrelated), isNull);
        expect(
            db.getAccount(unrelated.accountId)!.mediaCompanionOrigins, isEmpty);
      }
      expect(otherOwner.mediaCompanionDecision(otherPerson), isNull);
      expect(
          otherOwner.getAccount(otherPerson.accountId)!.mediaCompanionOrigins,
          isEmpty);

      final batch = (calls.single.arguments as Map)['accounts'] as List;
      expect(
          batch,
          unorderedEquals([
            for (final entry in [first, sibling])
              {
                'origin': account.url,
                'instanceBase': 'https://watch.example/videos',
                'origins': expected,
                'gatewayContext': GatewayRequestContext.forAccount(
                        entry.profileId, entry.accountId, entry.url)!
                    .encoded,
              },
          ]));
    }
  });

  test('declining setup survives deleting and readding the last account',
      () async {
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    mockMediaCompanionTransport();
    expect(db.mediaCompanionDecision(account), isNull);
    final initial = await db.addAccountWithMediaCompanions(account,
        isCurrent: () => true, setupDecision: {});
    expect(initial!.mediaCompanionOrigins, isEmpty);
    expect(db.mediaCompanionDecision(account), isEmpty);
    await db.deleteServerById(initial);

    final replacement = account.copyWith(id: 'new');
    expect(db.mediaCompanionDecision(replacement), isEmpty);
    final saved = await db.addAccountWithMediaCompanions(
        replacement.copyWith(mediaCompanionOrigins: [origin]),
        isCurrent: () => true,
        setupDecision: {origin});
    expect(saved!.mediaCompanionOrigins, isEmpty);
    expect(db.mediaCompanionDecision(replacement), isEmpty);
  });

  test('a legacy account grant stays local until an explicit decision',
      () async {
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    mockMediaCompanionTransport();
    final legacy = account.copyWith(mediaCompanionOrigins: [origin]);
    final empty = account.copyWith(id: 'old-empty');
    await db.serversStore.record(legacy.accountId).put(db.db, legacy.toJson());
    await db.serversStore
        .record(empty.accountId)
        .put(db.db, empty.toJson()..remove('mediaCompanionOrigins'));
    for (final existing in [legacy, empty]) {
      expect(db.mediaCompanionDecision(existing), isNull);
    }
    final sibling = await db.addAccountWithMediaCompanions(
        account.copyWith(id: 'new', mediaCompanionOrigins: [other]),
        isCurrent: () => true);
    expect(sibling!.mediaCompanionOrigins, isEmpty);
    expect(db.getAccount(legacy.accountId)!.mediaCompanionOrigins, [origin]);
    expect(db.getAccount(empty.accountId)!.mediaCompanionOrigins, isEmpty);
    await db.setMediaCompanionOrigin(empty, other, enabled: true);
    for (final existing in [legacy, empty, sibling]) {
      expect(db.getAccount(existing.accountId)!.mediaCompanionOrigins, [other]);
      expect(db.mediaCompanionDecision(existing), {other});
    }
  });

  test('concurrent setup decisions keep the first accepted choice', () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final firstWrite = Completer<void>();
    final release = Completer<void>();
    mockMediaCompanionTransport(onSetOrigins: (call) async {
      if (!firstWrite.isCompleted) {
        firstWrite.complete();
        await release.future;
      }
    });
    final first = db.addAccountWithMediaCompanions(account,
        isCurrent: () => true, setupDecision: {origin});
    await firstWrite.future;
    final second = db.addAccountWithMediaCompanions(
        account.copyWith(id: 'other-account'),
        isCurrent: () => true,
        setupDecision: {other});
    release.complete();
    final accounts = await Future.wait([first, second]);
    expect(accounts.map((result) => result!.mediaCompanionOrigins), [
      [origin],
      [origin]
    ]);
    expect(db.mediaCompanionDecision(account), {origin});
  });

  test('leaving setup during approval restores the previous sibling grants',
      () async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final sibling = account
        .copyWith(id: 'old', authToken: 'kept', mediaCompanionOrigins: [other]);
    await db.serversStore
        .record(sibling.accountId)
        .put(db.db, sibling.toJson());
    String gatewayKey(Server s) =>
        GatewayRequestContext.forAccount(s.profileId, s.accountId, s.url)!
            .encoded;
    final native = <String, List>{
      gatewayKey(sibling): [other]
    };
    var current = true;
    mockMediaCompanionTransport(onSetOrigins: (call) async {
      final batch = call.arguments as Map;
      for (final entry in (batch['accounts'] as List? ?? [batch]).cast<Map>()) {
        native[entry['gatewayContext'] as String] = entry['origins'] as List;
      }
      current = false;
    });
    final result = await db.addAccountWithMediaCompanions(account,
        setupDecision: {origin}, isCurrent: () => current);
    expect(result, isNull);
    expect(db.mediaCompanionDecision(sibling), isNull);
    expect(db.getAccount(account.accountId), isNull);
    expect(db.getAccount(sibling.accountId), sibling);
    expect(native[gatewayKey(sibling)], [other]);
    expect(native[gatewayKey(account)] ?? [], isEmpty);
  });

  test('deleting a profile removes its remembered instance decision', () async {
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    mockMediaCompanionTransport();
    final profile = await db.createProfile('Temporary');
    final removed = db.forProfile(profile.id);
    final formerAccount = account.copyWith(profileId: profile.id);
    await removed.addAccountWithMediaCompanions(formerAccount,
        isCurrent: () => true, setupDecision: {origin});
    expect(removed.mediaCompanionDecision(formerAccount), {origin});
    final decisions = stringMapStoreFactory
        .store('profile:${profile.id}:mediaCompanionDecisions');
    expect(await decisions.count(db.db), 1);
    await db.deleteProfile(profile.id);
    expect(await decisions.count(db.db), 0);
    expect(
        () => removed.mediaCompanionDecision(formerAccount), throwsStateError);
    expect(db.mediaCompanionDecision(account), isNull);
  });

  test('a refused profile removal preserves every native companion grant',
      () async {
    final platform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = platform);
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final profile = await db.createProfile('Temporary');
    final owner = db.forProfile(profile.id);
    final first = account.copyWith(profileId: profile.id, id: 'a');
    final second = first.copyWith(id: 'z');
    String key(Server server) => GatewayRequestContext.forAccount(
            server.profileId, server.accountId, server.url)!
        .encoded;
    final native = <String, List>{};
    var refuseRemoval = false;
    mockMediaCompanionTransport(onSetOrigins: (call) async {
      final batch = call.arguments as Map;
      final entries = (batch['accounts'] as List? ?? [batch]).cast<Map>();
      if (refuseRemoval &&
          entries.any((entry) =>
              entry['gatewayContext'] == key(second) &&
              (entry['origins'] as List).isEmpty)) {
        throw PlatformException(code: 'UNAVAILABLE');
      }
      for (final entry in entries) {
        native[entry['gatewayContext'] as String] = entry['origins'] as List;
      }
    });
    await owner.addAccountWithMediaCompanions(first,
        isCurrent: () => true, setupDecision: {origin});
    await owner.addAccountWithMediaCompanions(second, isCurrent: () => true);
    refuseRemoval = true;
    await expectLater(
        db.deleteProfile(profile.id), throwsA(isA<PlatformException>()));
    for (final server in [first, second]) {
      expect(
          owner.getAccount(server.accountId)!.mediaCompanionOrigins, [origin]);
      expect(native[key(server)], [origin]);
    }

    refuseRemoval = false;
    await db.deleteProfile(profile.id);
    expect((await db.getProfiles()).map((profile) => profile.id),
        isNot(contains(profile.id)));
    expect(native[key(first)], isEmpty);
    expect(native[key(second)], isEmpty);
  });
}
