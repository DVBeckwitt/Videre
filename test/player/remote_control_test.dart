import 'dart:convert';
import 'dart:io';

import 'package:clipious/player/remote_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RemoteReceiver receiver;
  late HttpClient http;
  late DateTime now;
  late List<RemoteCommand> commands;

  Future<(int, Map<String, dynamic>)> post(String path, Object body,
      {String? token}) async {
    final request =
        await http.postUrl(Uri.parse('http://127.0.0.1:${receiver.port}$path'));
    request.headers.contentType = ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    request.write(jsonEncode(body));
    final response = await request.close();
    final value = jsonDecode(await response.transform(utf8.decoder).join());
    return (response.statusCode, value as Map<String, dynamic>);
  }

  setUp(() async {
    now = DateTime.utc(2026);
    commands = [];
    http = HttpClient();
    receiver = await RemoteReceiver.start(
        address: InternetAddress.loopbackIPv4,
        now: () => now,
        onCommand: commands.add);
  });

  tearDown(() async {
    http.close(force: true);
    await receiver.close();
  });

  test('pairs once, transfers an exact paused position and revokes disconnect',
      () async {
    final paired = await post('/pair', {'code': receiver.code});
    expect(paired.$1, HttpStatus.ok);
    final token = paired.$2['token'] as String;
    expect(receiver.paired, isTrue);
    expect((await post('/pair', {'code': receiver.code})).$1,
        HttpStatus.unauthorized);
    expect(
        (await post(
                '/command',
                {
                  'action': 'load',
                  'videoId': 'dQw4w9WgXcQ',
                  'position': 123,
                  'playing': false,
                },
                token: token))
            .$1,
        HttpStatus.ok);
    expect(commands.single.videoId, 'dQw4w9WgXcQ');
    expect(commands.single.position, 123);
    expect(commands.single.playing, isFalse);
    for (final action in ['play', 'pause', 'disconnect']) {
      now = now.add(const Duration(seconds: 1));
      expect((await post('/command', {'action': action}, token: token)).$1,
          HttpStatus.ok);
    }
    expect(
        commands.map((command) => command.action), ['load', 'play', 'pause']);
    expect(receiver.paired, isFalse);
    expect((await post('/command', {'action': 'play'}, token: token)).$1,
        HttpStatus.unauthorized);
  });

  test('rejects missing credentials, wrong codes and expired codes', () async {
    expect((await post('/command', {'action': 'play'})).$1,
        HttpStatus.unauthorized);
    expect(
        (await post('/pair', {'code': 'wrong'})).$1, HttpStatus.unauthorized);
    now = now.add(const Duration(minutes: 5));
    expect(receiver.codeExpired, isTrue);
    expect((await post('/pair', {'code': receiver.code})).$1,
        HttpStatus.unauthorized);
    expect(commands, isEmpty);
  });

  test('rejects browser-origin pairing and disconnect always revokes the token',
      () async {
    final request =
        await http.postUrl(Uri.parse('http://127.0.0.1:${receiver.port}/pair'));
    request.headers.set('origin', 'https://example.com');
    request.write(jsonEncode({'code': receiver.code}));
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, HttpStatus.forbidden);
    final token =
        (await post('/pair', {'code': receiver.code})).$2['token'] as String;
    await post('/command', {'action': 'play'}, token: token);
    // Disconnect must work even when playback just used the command rate limit.
    expect((await post('/command', {'action': 'disconnect'}, token: token)).$1,
        HttpStatus.ok);
    expect(receiver.paired, isFalse);
  });

  test('limits pairing attempts and command rate', () async {
    for (var attempt = 0; attempt < 6; attempt++) {
      await post('/pair', {'code': 'wrong'});
    }
    expect((await post('/pair', {'code': receiver.code})).$1,
        HttpStatus.tooManyRequests);
    now = now.add(const Duration(minutes: 1));
    final token =
        (await post('/pair', {'code': receiver.code})).$2['token'] as String;
    await post('/command', {'action': 'play'}, token: token);
    expect((await post('/command', {'action': 'pause'}, token: token)).$1,
        HttpStatus.tooManyRequests);
    expect(commands.length, 1);
  });

  test('rejects URLs, invalid positions, malformed and oversized messages',
      () async {
    final token =
        (await post('/pair', {'code': receiver.code})).$2['token'] as String;
    for (final body in <Object>[
      [],
      {
        'action': 'load',
        'videoId': 'https://example.com',
        'position': 0,
        'playing': true
      },
      for (final position in [-1, 604801, 1.5, '10'])
        {
          'action': 'load',
          'videoId': 'dQw4w9WgXcQ',
          'position': position,
          'playing': true
        },
      {'action': 'unknown'},
    ]) {
      expect((await post('/command', body, token: token)).$1,
          HttpStatus.badRequest);
    }
    expect(commands, isEmpty);
    try {
      expect(
          (await post('/command', {'action': 'load', 'videoId': 'x' * 2048},
                  token: token))
              .$1,
          HttpStatus.badRequest);
    } on HttpException {
      // Dart may close the socket when an oversized request body is cancelled.
    }
    expect(commands, isEmpty);
    http.close(force: true);
    http = HttpClient();
    expect((await post('/command', {'action': 'pause'}, token: token)).$1,
        HttpStatus.ok);
  });

  test('client only accepts local addresses and sends authenticated commands',
      () async {
    for (final address in [
      'example.com:80',
      '8.8.8.8:80',
      'https://192.168.1.1:80',
      '192.168.1.1',
      'http://user@192.168.1.1:80',
      '192.168.1.1:80/path',
    ]) {
      expect(() => RemoteClient(address), throwsFormatException);
    }
    final client = RemoteClient('127.0.0.1:${receiver.port}');
    addTearDown(client.close);
    await client.pair(receiver.code);
    await client.send(const RemoteCommand('pause'));
    expect(commands.single.action, 'pause');
    await receiver.close();
    expect(receiver.paired, isFalse);
    await expectLater(
        client.send(const RemoteCommand('play')), throwsA(isA<Exception>()));
  });
}
