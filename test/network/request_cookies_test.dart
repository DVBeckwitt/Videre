import 'package:clipious/globals.dart';
import 'package:clipious/service.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/request_cookies.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('request cookie editing', () {
    test('reads case-insensitive headers but case-sensitive cookie names', () {
      const headers = {
        'cOoKiE': ' backend=6 ; Backend=different; SID=session== ',
      };

      expect(requestCookieValue(headers, 'backend'), '6');
      expect(requestCookieValue(headers, 'Backend'), 'different');
      expect(requestCookieValue(headers, 'SID'), 'session==');
      expect(requestCookieValue(headers, 'missing'), isNull);
    });

    test('replaces a routing cookie without changing unrelated state', () {
      const headers = {
        'cookie': 'backend=2; PREFS=encoded==',
        'Cookie': 'SID=session; Backend=different',
        'X-Instance-Header': 'preserved',
      };

      final updated = withRequestCookie(headers, 'backend', '6');

      expect(updated, {
        'Cookie': 'backend=6; PREFS=encoded==; SID=session; Backend=different',
        'X-Instance-Header': 'preserved',
      });
      expect(headers['cookie'], 'backend=2; PREFS=encoded==');
    });

    test('removing routing preference retains login and other cookies', () {
      final updated = withRequestCookie(
          {'Cookie': 'backend=6; SID=session; PREFS=encoded'}, 'backend', null);

      expect(updated, {'Cookie': 'SID=session; PREFS=encoded'});
      expect(requestCookieValue(updated, 'backend'), isNull);
    });

    test('routing edits preserve duplicate unrelated cookie pairs', () {
      const headers = {
        'cookie': 'SID=first; backend=old; other=one',
        'Cookie': 'SID=second; backend=stale; other=two; Backend=separate',
      };
      final selected = withRequestCookie(headers, 'backend', 'new');
      expect(selected, {
        'Cookie': 'SID=first; backend=new; other=one; '
            'SID=second; other=two; Backend=separate',
      });
      expect(withRequestCookie(selected, 'backend', null), {
        'Cookie': 'SID=first; other=one; SID=second; '
            'other=two; Backend=separate',
      });
      expect(requestCookieValue(headers, 'SID'), 'second');
    });

    test('removing the last cookie leaves no empty Cookie header', () {
      expect(
          withRequestCookie(
              {'COOKIE': 'backend=6', 'Accept': 'application/json'},
              'backend',
              null),
          {'Accept': 'application/json'});
    });

    test('empty cookie values differ from an absent preference', () {
      final updated = withRequestCookie({}, 'backend', '');

      expect(updated, {'Cookie': 'backend='});
      expect(requestCookieValue(updated, 'backend'), '');
      expect(withRequestCookie(updated, 'backend', null), isEmpty);
    });

    test('merged login cookies replace only matching case-sensitive names', () {
      const headers = {
        'Cookie': 'backend=6; SID=old; sid=separate; PREFS=encoded==',
      };

      expect(mergeRequestCookies(headers, 'SID=new=='), {
        'Cookie': 'backend=6; SID=new==; sid=separate; PREFS=encoded==',
      });
      expect(headers['Cookie'],
          'backend=6; SID=old; sid=separate; PREFS=encoded==');
    });

    test('login merge replaces duplicate SID but preserves other duplicates',
        () {
      const headers = {
        'Cookie': 'route=one; SID=first; route=two; SID=second; sid=separate',
      };
      expect(mergeRequestCookies(headers, 'SID=account'), {
        'Cookie': 'route=one; SID=account; route=two; sid=separate',
      });
    });
  });

  group('server request cookies', () {
    late Service service;

    setUp(() async {
      db = await SembastSqfDb.createInMemory();
      service = Service();
    });

    tearDown(() async {
      service.httpClient.close();
      await db.close();
    });

    test('public requests keep routing cookies without adding account cookies',
        () async {
      const server = Server(
        url: 'https://instance.example',
        sidCookie: 'SID=account-session',
        customHeaders: {'Cookie': 'backend=6; PREFS=encoded-preferences'},
      );
      final request =
          await service.buildRequest(urlStats, serverOverride: server);

      expect(request.headers['Cookie'], 'backend=6; PREFS=encoded-preferences');
      expect(request.headers.containsKey('Authorization'), isFalse);
    });

    test('token authentication preserves routing cookies', () async {
      const server = Server(
        url: 'https://instance.example',
        authToken: 'account-token',
        customHeaders: {'Cookie': 'backend=6'},
      );
      final request = await service.buildRequest(urlGetSubscriptions,
          authenticated: true, serverOverride: server);

      expect(request.headers['Cookie'], 'backend=6');
      expect(request.headers['Authorization'], 'Bearer account-token');
    });

    test('SID authentication merges account and routing cookies', () async {
      const server = Server(
        url: 'https://instance.example',
        sidCookie: 'SID=account-session',
        customHeaders: {'Cookie': 'backend=6; PREFS=encoded-preferences'},
      );
      final request = await service.buildRequest(urlGetSubscriptions,
          authenticated: true, serverOverride: server);

      expect(request.headers['Cookie'],
          'backend=6; PREFS=encoded-preferences; SID=account-session');
    });

    test('mixed-case cookie headers cannot duplicate or override login SID',
        () async {
      const server = Server(
        url: 'https://instance.example',
        sidCookie: 'SID=account-session',
        customHeaders: {
          'cOoKiE': 'backend=6; SID=stale-session',
          'Cookie': 'PREFS=encoded-preferences',
        },
      );
      final request = await service.buildRequest(urlGetSubscriptions,
          authenticated: true, serverOverride: server);

      expect(
          request.headers.keys.where((name) => name.toLowerCase() == 'cookie'),
          ['Cookie']);
      expect(request.headers['Cookie'],
          'backend=6; SID=account-session; PREFS=encoded-preferences');
    });
  });

  test('routing headers stay restricted to the selected server origin', () {
    const server = Server(
      url: 'https://instance.example',
      customHeaders: {'Cookie': 'backend=6'},
    );

    expect(server.headersForUrl('https://instance.example/videoplayback'),
        {'Cookie': 'backend=6'});
    for (final target in [
      'https://another.example/videoplayback',
      'https://instance.example.evil.test/videoplayback',
      'https://media.instance.example/videoplayback',
      'http://instance.example/videoplayback',
      'https://instance.example:8443/videoplayback',
    ]) {
      expect(server.headersForUrl(target), isNull, reason: target);
    }
  });
}
