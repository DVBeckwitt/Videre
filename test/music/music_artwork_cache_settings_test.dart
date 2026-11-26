import 'dart:async';

import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/db/home_layout.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artwork_cache.dart';
import 'package:clipious/music/services/device_music_artwork_cache.dart';
import 'package:clipious/music/services/music_artwork_cache.dart';
import 'package:clipious/player/notification_artwork_cache.dart';
import 'package:clipious/settings/views/components/music_artwork_cache_settings.dart';
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

class _App extends Cubit<AppState> implements AppCubit {
  _App() : super(AppState(0, null, HomeLayout()));

  void simulateSessionChange(String profile) => emit(state.copyWith(
      profileId: profile, sessionRevision: state.sessionRevision + 1));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Cache extends Fake implements MusicArtworkCache {
  var status = (usedBytes: 2048, limitMiB: 128, hasTransfers: false);
  int reads = 0;
  int clears = 0;
  final limits = <int>[];
  Completer<MusicArtworkCacheStatus>? pendingRead;
  Completer<void>? pendingConfigure;
  IDbClient? owner;

  @override
  Future<MusicArtworkCacheStatus> read(IDbClient owner) async {
    this.owner = owner;
    reads++;
    return pendingRead?.future ?? Future.value(status);
  }

  @override
  Future<MusicArtworkCacheStatus> configure(IDbClient owner, int limitMiB,
      {bool Function()? isCurrent}) async {
    await pendingConfigure?.future;
    if (!isCurrent!()) throw StateError('Stale cache settings');
    expect(owner, same(this.owner));
    limits.add(limitMiB);
    return status = (
      usedBytes: status.usedBytes,
      limitMiB: limitMiB,
      hasTransfers: status.hasTransfers,
    );
  }

  @override
  Future<MusicArtworkCacheStatus> clear(IDbClient owner,
      {bool Function()? isCurrent}) async {
    expect(isCurrent!(), isTrue);
    expect(owner, same(this.owner));
    clears++;
    return status = (
      usedBytes: 0,
      limitMiB: status.limitMiB,
      hasTransfers: false,
    );
  }
}

class _DeviceCache extends Fake
    implements DeviceMusicArtworkCache, NotificationArtworkCache {
  _DeviceCache(this.bytes, this.limitMiB);

  int bytes;
  final int limitMiB;
  int reads = 0;
  int clears = 0;
  bool failRead = false;

  @override
  Future<DeviceMusicArtworkCacheStatus> read() async {
    reads++;
    if (failRead) throw StateError('Unavailable cache');
    return (
      usedBytes: bytes,
      limitBytes: limitMiB * 1024 * 1024,
      canClear: bytes > 0,
    );
  }

  @override
  Future<DeviceMusicArtworkCacheStatus> clear() async {
    clears++;
    bytes = 0;
    return (
      usedBytes: bytes,
      limitBytes: limitMiB * 1024 * 1024,
      canClear: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _App app;
  late _Cache cache;
  final entry = find.byKey(const ValueKey('music-artwork-cache-setting'));
  final clear = find.byKey(const ValueKey('music-artwork-cache-clear'));
  final confirm = find.byKey(const ValueKey('music-artwork-cache-confirm'));

  setUp(() async {
    db = await SembastSqfDb.createInMemory();
    app = _App();
    cache = _Cache();
  });
  tearDown(() async {
    await app.close();
    await db.close();
  });

  Future<void> showTile(WidgetTester tester) async {
    await tester.pumpWidget(BlocProvider<AppCubit>.value(
      value: app,
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: MusicArtworkCacheSettings(cache: cache))),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'artwork storage reads on demand, limits size and confirms clearing',
      (tester) async {
    await showTile(tester);
    expect(cache.reads, 0);
    await tap(tester, entry);
    expect(find.text('Stored artwork: 2 KiB'), findsOneWidget);
    await tap(tester, find.byType(DropdownButtonFormField<int>));
    for (final limit in musicArtworkCacheLimitsMiB) {
      expect(find.text('$limit MiB'), findsWidgets);
    }
    await tap(tester, find.text('64 MiB').last);
    expect(cache.limits, [64]);
    expect(cache.clears, 0);
    await tap(tester, clear);
    await tap(tester, find.text('Cancel'));
    expect(cache.clears, 0);
    expect(find.text('Stored artwork: 2 KiB'), findsOneWidget);
    await tap(tester, clear);
    await tap(tester, confirm);
    expect(cache.clears, 1);
    expect(find.text('Stored artwork: 0 B'), findsOneWidget);
    expect(tester.widget<TextButton>(clear).onPressed, isNull);
  });

  testWidgets('artwork storage shows progress and retries a failed read',
      (tester) async {
    await showTile(tester);
    cache.pendingRead = Completer<MusicArtworkCacheStatus>();
    await tester.tap(entry);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    cache.pendingRead!.completeError(StateError('Unavailable cache'));
    await tester.pumpAndSettle();
    expect(find.text('Could not update artwork storage.'), findsOneWidget);
    expect(clear, findsNothing);
    cache.pendingRead = null;
    await tap(tester, find.text('Refresh'));
    expect(cache.reads, 2);
    expect(find.text('Stored artwork: 2 KiB'), findsOneWidget);
    expect(cache.limits, isEmpty);
    expect(cache.clears, 0);
  });

  testWidgets('Clear is available while artwork is awaiting its first bytes',
      (tester) async {
    cache.status = (usedBytes: 0, limitMiB: 128, hasTransfers: true);
    await showTile(tester);
    await tap(tester, entry);
    expect(find.text('Stored artwork: 0 B'), findsOneWidget);
    expect(tester.widget<TextButton>(clear).onPressed, isNotNull);

    await tap(tester, clear);
    await tap(tester, confirm);
    expect(cache.clears, 1);
    expect(tester.widget<TextButton>(clear).onPressed, isNull);
  });

  testWidgets(
      'a profile switch disables an open confirmation and hides old usage',
      (tester) async {
    await showTile(tester);
    await tap(tester, entry);
    await tap(tester, clear);
    final second = (await tester.runAsync(() => db.createProfile('Second')))!;
    await tester.runAsync(() => db.useProfile(second.id));
    app.simulateSessionChange(second.id);
    await tester.pumpAndSettle();
    expect(cache.owner!.profileId, isNot(second.id));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tap(tester, find.text('Cancel'));
    expect(clear, findsNothing);
    expect(find.text('Stored artwork: 2 KiB'), findsNothing);
    expect(cache.clears, 0);
    expect(cache.reads, 1);
  });

  testWidgets('a delayed limit change cannot apply after a session change',
      (tester) async {
    await showTile(tester);
    await tap(tester, entry);
    cache.pendingConfigure = Completer<void>();
    await tap(tester, find.byType(DropdownButtonFormField<int>));
    await tester.tap(find.text('32 MiB').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    app.simulateSessionChange(db.profileId);
    await tester.pump();
    cache.pendingConfigure!.complete();
    await tester.pumpAndSettle();
    expect(cache.limits, isEmpty);
    expect(clear, findsNothing);
  });

  final deviceEntry = find.byKey(
    const ValueKey('music-device-artwork-cache-setting'),
  );
  final notificationEntry = find.byKey(
    const ValueKey('music-notification-artwork-cache-setting'),
  );
  final deviceClear = find.byKey(
    const ValueKey('music-device-artwork-cache-clear'),
  );
  final deviceConfirm = find.byKey(
    const ValueKey('music-device-artwork-cache-confirm'),
  );

  Future<void> showDeviceTiles(
    WidgetTester tester,
    _DeviceCache device,
    _DeviceCache notification,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MusicDeviceArtworkSettings(
            deviceCache: device,
            notificationCache: notification,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'reads and clears Android artwork stores independently',
    (tester) async {
      final device = _DeviceCache(2048, 24);
      final notification = _DeviceCache(3072, 32);
      await showDeviceTiles(tester, device, notification);
      expect(device.reads + notification.reads, 0);

      await tap(tester, deviceEntry);
      expect(find.text('Stored artwork: 2 KiB'), findsOneWidget);
      expect(
        find.text('Storage limit per library source: 24 MiB'),
        findsOneWidget,
      );
      expect(notification.reads, 0);
      await tap(tester, deviceClear);
      await tap(tester, find.text('Cancel'));
      expect(device.clears, 0);
      await tap(tester, deviceClear);
      await tap(tester, deviceConfirm);
      expect(device.clears, 1);
      expect(find.text('Stored artwork: 0 B'), findsOneWidget);
      expect(tester.widget<TextButton>(deviceClear).onPressed, isNull);
      await tap(tester, find.text('Close'));

      await tap(tester, notificationEntry);
      expect(find.text('Stored artwork: 3 KiB'), findsOneWidget);
      expect(find.text('Storage limit: 32 MiB'), findsOneWidget);
      await tap(tester, deviceClear);
      expect(
        find.text(
          'Clears cached copies of notification images. Artwork already displayed in the current notification stays visible.',
        ),
        findsOneWidget,
      );
      await tap(tester, deviceConfirm);
      expect(device.clears, 1);
      expect(notification.clears, 1);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'retries a failed Android artwork store independently',
    (tester) async {
      final device = _DeviceCache(2048, 24);
      final notification = _DeviceCache(3072, 32)..failRead = true;
      await showDeviceTiles(tester, device, notification);
      await tap(tester, notificationEntry);
      expect(find.text('Could not update artwork storage.'), findsOneWidget);
      expect(deviceClear, findsNothing);

      notification.failRead = false;
      await tap(tester, find.text('Refresh'));
      expect(notification.reads, 2);
      expect(device.reads, 0);
      expect(find.text('Stored artwork: 3 KiB'), findsOneWidget);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'hides the Android artwork controls on iOS',
    (tester) async {
      await showDeviceTiles(
        tester,
        _DeviceCache(2048, 24),
        _DeviceCache(3072, 32),
      );
      expect(deviceEntry, findsNothing);
      expect(notificationEntry, findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
