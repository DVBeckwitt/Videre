import 'dart:async';
import 'dart:convert';

import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/player/models/backend_playback.dart';
import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final selector = BackendSelector('ROUTE', const [
    BackendOption('a', 'A'),
    BackendOption('b', 'B'),
    BackendOption('c', 'C'),
    BackendOption('d', 'D'),
  ]);
  final preferred =
      selector.withSelection(const Server(url: 'https://example.test'), 'a');
  final outage = InvidiousServiceError('unavailable',
      statusCode: 500,
      errorCode: 'This backend is blocked by Youtube. Please wait '
          'until it has refreshed itself or switch to another backend.');
  late DateTime now;
  late BackendHealth health;

  setUp(() {
    now = DateTime.utc(2026);
    health = BackendHealth(now: () => now);
  });

  BackendPlayback fresh([Server? server]) =>
      BackendPlayback(server ?? preferred, health: health);
  BackendPlayback choose(String id) =>
      BackendPlayback.manual(preferred, id, health: health);

  test(
      'fresh traffic ranks proven routes ahead of unknown, skips known outages',
      () {
    choose('b').recordFailure(outage);
    choose('d').recordSuccess();
    final first = fresh();
    expect(first.label, 'A');
    final second = first.next()!;
    final third = second.next()!;
    expect([second.label, third.label], ['D', 'C']);
    expect(third.canRetry, isFalse);
    expect(first.retries, 2);
    expect(choose('b').label, 'B'); // Manual selection stays available.

    now = now.add(const Duration(minutes: 2));
    final afterCooldown = fresh().next()!;
    expect(afterCooldown.label, 'D');
    expect(afterCooldown.next()!.label, 'B');
    now = now.add(const Duration(minutes: 3));
    expect(fresh().next()!.label, 'B');
  });

  test('no eligible alternate spends no attempts and expiry restores order',
      () {
    for (final value in ['b', 'c', 'd']) {
      choose(value).recordFailure(outage);
    }
    final route = fresh();
    expect(route.canRetry, isFalse);
    expect(route.acquireRecovery(), isFalse);
    expect(route.next(), isNull);
    expect(route.retries, 0);
    now = now.add(const Duration(minutes: 2));
    expect(route.next()!.label, 'B');
  });

  test('failures unrelated to a backend do not quarantine it', () {
    final transient = [
      TimeoutException('local network'),
      const BackendPlaybackFailure(),
      for (final status in [401, 403, 404, 429, 500])
        InvidiousServiceError('error', statusCode: status),
      InvidiousServiceError('upstream cooldown',
          statusCode: 503, retryAfter: const Duration(seconds: 1)),
      for (final delay in [Duration.zero, const Duration(seconds: 3)])
        InvidiousServiceError('cooldown',
            statusCode: 500, errorCode: outage.errorCode, retryAfter: delay),
      InvidiousServiceError('cooldown',
          statusCode: 500,
          errorCode: outage.errorCode,
          retryAfterIsInvalid: true),
      InvidiousServiceError('gateway',
          statusCode: 500,
          errorCode: 'credentials_required',
          isGatewayResponse: true),
    ];
    for (final error in transient) {
      choose('b').recordFailure(error);
    }
    expect(fresh().next()!.label, 'B');
    choose('b').recordFailure(InvidiousServiceError('companion',
        statusCode: 500, errorCode: outage.errorCode, isGatewayResponse: true));
    expect(fresh().next()!.label, 'C');
  });

  test('upstream errors yield to an untried alternate on the next item', () {
    final first = fresh();
    final b = first.next()!;
    final c = b.next()!;
    for (final (status, route) in [(502, first), (503, b), (504, c)]) {
      route
          .recordFailure(InvidiousServiceError('upstream', statusCode: status));
    }
    expect(c.next(), isNull);
    final next = fresh();
    expect(next.next()!.label, 'D');
    // The less promising routes are still eligible if nothing else is left.
    expect(next.next()!.label, 'B');
    now = now.add(const Duration(seconds: 30));
    expect(fresh().next()!.label, 'B');
  });

  test('late successes cannot replace newer backend outage evidence', () {
    final old = choose('b');
    final recent = choose('b');
    recent.recordSuccess();
    recent.recordFailure(outage);
    old.recordSuccess();
    recent.recordSuccess();
    expect(fresh().next()!.label, 'C');
    choose('b').recordSuccess();
    expect(fresh().next()!.label, 'B');
  });

  test('scope is isolated by session, profile, instance, account and selector',
      () {
    choose('d').recordSuccess();
    expect(fresh().next()!.label, 'D');
    for (final other in [
      preferred.copyWith(url: 'https://another.test'),
      preferred.copyWith(profileId: 'separate-profile'),
      preferred.copyWith(id: 'separate-account'),
      preferred.copyWith(authToken: 'new-session'),
      preferred.copyWith(
          customHeaders: {...preferred.customHeaders, 'X-Scope': '2'}),
      preferred.copyWith(
          backendSelector: BackendSelector('ROUTE', [
        ...selector.options,
        const BackendOption('e', 'E'),
      ])),
    ]) {
      expect(fresh(other).next()!.label, 'B');
    }
    final retired = choose('d');
    final oldRequest = fresh();
    health.retire();
    health = BackendHealth(now: () => now);
    retired.recordSuccess();
    expect(oldRequest.next()!.label, 'B');
    expect(fresh().next()!.label, 'B');
    expect(
        fresh(preferred.copyWith(
                backendSelector: selector.copyWith(automaticFallback: false)))
            .next(),
        isNull);
  });

  test('an unidentified automatic route cannot mark a named backend', () {
    BackendPlayback(selector.withSelection(preferred, null), health: health)
        .recordFailure(outage);
    expect(fresh().next()!.label, 'B');
  });

  test(
      'new proxy configuration retires observations and subsequent old results',
      () async {
    final saved = jsonEncode(NetworkProxy.instance.config.toJson());
    addTearDown(() =>
        NetworkProxy.instance.initialize(saved: saved, configureNative: false));
    final old = choose('d');
    old.recordSuccess();
    expect(fresh().next()!.label, 'D');
    await NetworkProxy.instance
        .initialize(saved: saved, configureNative: false);
    old.recordSuccess();
    expect(old.next(), isNull);
    expect(fresh().next()!.label, 'B');
  });
}
