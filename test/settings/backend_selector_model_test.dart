import 'dart:convert';

import 'package:clipious/settings/models/backend_selector.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final plain = BackendSelector('COMPANION_ID', const [
    BackendOption('0', 'First'),
    BackendOption('5', 'Sixth'),
  ]);
  final preferences = BackendSelector(
      'PREFS',
      const [
        BackendOption('0', 'First'),
        BackendOption('4', 'Fifth'),
      ],
      preferenceField: 'current_companion');
  const server = Server(url: 'https://instance.example');

  test('plain selection preserves other cookies, account and headers', () {
    final original = server.copyWith(
      sidCookie: 'SID=account-session',
      customHeaders: {
        'cookie': 'SID=manual-session; PREFS=encoded==; COMPANION_ID=unknown',
        'X-Instance': 'kept',
      },
    );
    expect(plain.selectedValue(original), 'unknown');
    expect(plain.labelFor('unknown'), isNull);
    final selected = plain.withSelection(original, '0');
    expect(selected.backendSelector, plain);
    expect(selected.sidCookie, original.sidCookie);
    expect(selected.customHeaders, {
      'Cookie': 'SID=manual-session; PREFS=encoded==; COMPANION_ID=0',
      'X-Instance': 'kept',
    });
    expect(plain.withSelection(selected, null).customHeaders, {
      'Cookie': 'SID=manual-session; PREFS=encoded==',
      'X-Instance': 'kept',
    });
    expect(original.customHeaders['cookie'], contains('COMPANION_ID=unknown'));
  });

  test('generic plain cookies retain string values including equals', () {
    final selector = BackendSelector('ROUTE', const [
      BackendOption('region-one', 'Region one'),
      BackendOption('value==', 'Encoded value'),
    ]);
    final selected = selector.withSelection(server, 'value==');
    expect(selector.selectedValue(selected), 'value==');
    expect(selected.customHeaders, {'Cookie': 'ROUTE=value=='});
  });

  test('preferences selection merges numeric ID into form-encoded JSON', () {
    final existing = {
      'dark_mode': 'dark',
      'caption_text': 'two words + accented é',
      'nested': {'preserve': true},
      'current_companion': 0,
    };
    final original = server.copyWith(customHeaders: {
      'Cookie': 'SID=manual-session; '
          'PREFS=${Uri.encodeQueryComponent(jsonEncode(existing))}; other=kept',
    });
    final selected = preferences.withSelection(original, '4');
    final encoded = requestCookieValue(selected.customHeaders, 'PREFS')!;
    expect(jsonDecode(Uri.decodeQueryComponent(encoded)), {
      ...existing,
      'current_companion': 4,
    });
    expect(preferences.selectedValue(selected), '4');
    expect(requestCookieValue(selected.customHeaders, 'SID'), 'manual-session');
    expect(requestCookieValue(selected.customHeaders, 'other'), 'kept');
    expect(preferences.selectedValue(original), '0');
  });

  test('preferences Automatic removes only current_companion', () {
    final original = server.copyWith(customHeaders: {
      'Cookie': 'PREFS=${Uri.encodeQueryComponent(jsonEncode({
            'dark_mode': 'dark',
            'current_companion': 4,
          }))}; SID=manual-session',
    });
    final automatic = preferences.withSelection(original, null);
    final encoded = requestCookieValue(automatic.customHeaders, 'PREFS')!;
    expect(
        jsonDecode(Uri.decodeQueryComponent(encoded)), {'dark_mode': 'dark'});
    expect(preferences.selectedValue(automatic), isNull);
    expect(
        requestCookieValue(automatic.customHeaders, 'SID'), 'manual-session');
    expect(preferences.withSelection(server, null).customHeaders, isEmpty);
    expect(preferences.selectedValue(server), isNull);
  });

  test('preferences selection creates a cookie without other preferences', () {
    final selected = preferences.withSelection(server, '0');
    expect(
        jsonDecode(Uri.decodeQueryComponent(
            requestCookieValue(selected.customHeaders, 'PREFS')!)),
        {'current_companion': 0});
    expect(preferences.selectedValue(selected), '0');
  });

  test('malformed preferences cannot be silently overwritten', () {
    for (final value in ['not-json', '%zz', '%5B1%5D', '%22string%22']) {
      final original =
          server.copyWith(customHeaders: {'Cookie': 'PREFS=$value'});
      expect(preferences.selectedValue(original), isNull);
      expect(() => preferences.withSelection(original, '0'),
          throwsFormatException);
      expect(() => preferences.withSelection(original, null),
          throwsFormatException);
      expect(original.customHeaders['Cookie'], 'PREFS=$value');
    }
  });

  test('unknown preference ID is retained until an explicit selection', () {
    final original = server.copyWith(customHeaders: {
      'Cookie': 'PREFS=${Uri.encodeQueryComponent('{"current_companion":99}')}',
    });
    expect(preferences.selectedValue(original), '99');
    expect(preferences.labelFor('99'), isNull);
    expect(
        () => preferences.withSelection(original, '99'), throwsArgumentError);
    expect(
        () => preferences.withSelection(original, '-1'), throwsArgumentError);
  });

  test('selector options are immutable and fallback defaults to enabled', () {
    final options = [const BackendOption('0', 'First')];
    final selector = BackendSelector('route', options);
    options.add(const BackendOption('1', 'Second'));
    expect(selector.options, [const BackendOption('0', 'First')]);
    expect(() => selector.options.clear(), throwsUnsupportedError);
    expect(selector.automaticFallback, isTrue);
    final disabled = selector.copyWith(automaticFallback: false);
    expect(disabled.automaticFallback, isFalse);
    expect(disabled.cookieName, selector.cookieName);
    expect(disabled.options, selector.options);
    expect(selector.automaticFallback, isTrue);
  });

  test('invalid configuration cannot create or overwrite cookies', () {
    for (final name in ['', 'bad name', 'route\r\nX-Test', 'SID', 'sid']) {
      expect(() => BackendSelector(name, plain.options), throwsArgumentError);
    }
    for (final value in ['', 'x; SID=changed', 'x\r\n', 'two words', 'é']) {
      expect(() => BackendSelector('route', [BackendOption(value, 'Label')]),
          throwsArgumentError);
    }
    expect(() => BackendSelector('route', const []), throwsArgumentError);
    expect(
        () => BackendSelector('route', const [
              BackendOption('0', 'First'),
              BackendOption('0', 'Duplicate'),
            ]),
        throwsArgumentError);
    expect(() => BackendSelector('PREFS', plain.options), throwsArgumentError);
    expect(
        () => BackendSelector('route', plain.options,
            preferenceField: 'current_companion'),
        throwsArgumentError);
    expect(
        () => BackendSelector('PREFS', plain.options, preferenceField: 'other'),
        throwsArgumentError);
    for (final value in ['-1', '01', 'region-one', '2147483648']) {
      expect(
          () => BackendSelector('PREFS', [BackendOption(value, 'Label')],
              preferenceField: 'current_companion'),
          throwsArgumentError);
    }
  });

  test('stored configuration round trips without model objects in maps', () {
    final configured = preferences.withSelection(server, '4').copyWith(
          backendSelector: preferences.copyWith(automaticFallback: true),
        );
    final data = configured.toJson();
    final selector = data['backendSelector'] as Map<String, dynamic>;
    expect(selector['options'], everyElement(isA<Map<String, dynamic>>()));
    expect(Server.fromJson(data), configured);
    expect(Server.fromJson(jsonDecode(jsonEncode(data))), configured);
    expect(BackendSelector.fromJson(selector), configured.backendSelector);
  });

  test(
      'missing fallback preference defaults on while explicit opt-out survives',
      () {
    final withoutPreference = plain.toJson()..remove('automaticFallback');
    expect(
        BackendSelector.fromJson(withoutPreference).automaticFallback, isTrue);
    final disabled = BackendSelector.fromJson({
      ...withoutPreference,
      'automaticFallback': false,
    });
    expect(disabled.automaticFallback, isFalse);
    expect(
        BackendSelector.fromJson(disabled.toJson()).automaticFallback, isFalse);
    final restored = Server.fromJson({
      'url': server.url,
      'backendSelector': disabled.toJson(),
    });
    expect(restored.backendSelector!.automaticFallback, isFalse);
  });
  test('old or malformed optional configuration leaves the server usable', () {
    expect(Server.fromJson({'url': server.url}).backendSelector, isNull);
    for (final invalid in [
      null,
      'invalid',
      [],
      {},
      {'cookieName': 'route', 'options': []},
      {
        'cookieName': 'route',
        'options': [null],
      },
      {
        ...plain.toJson(),
        'automaticFallback': 'true',
      },
      {
        ...plain.toJson(),
        'cookieName': 'SID',
      },
    ]) {
      final loaded = Server.fromJson({
        'url': server.url,
        'sidCookie': 'SID=account-session',
        'customHeaders': {'Cookie': 'COMPANION_ID=5'},
        'backendSelector': invalid,
      });
      expect(loaded.backendSelector, isNull);
      expect(loaded.sidCookie, 'SID=account-session');
      expect(loaded.customHeaders, {'Cookie': 'COMPANION_ID=5'});
    }
  });

  test('Sembast saves nested config and retains it when switching servers',
      () async {
    final db = await SembastSqfDb.createInMemory();
    addTearDown(db.close);
    final configured = plain.withSelection(server, '5');
    await db.upsertServer(configured);
    await db.upsertServer(const Server(url: 'https://other.example'));
    await db.useServer(db.getServer('https://other.example')!);
    await db.useServer(db.getServer(server.url)!);
    final loaded = await db.getCurrentlySelectedServer();
    expect(loaded.backendSelector, plain);
    expect(plain.selectedValue(loaded), '5');
  });
}
