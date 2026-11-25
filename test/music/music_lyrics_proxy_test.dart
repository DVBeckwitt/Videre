import 'dart:convert';
import 'dart:io';

import 'package:clipious/globals.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_preferences.dart';
import 'package:clipious/music/services/music_lyrics_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/network/socks_proxy.dart';
import 'package:clipious/utils/sembast_sqflite_database.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/rejecting_socks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final search in [false, true]) {
    final action = search ? 'manual search' : 'automatic lookup';
    test('opted-in lyrics $action routes through the configured SOCKS proxy',
        () async {
      db = await SembastSqfDb.createInMemory();
      addTearDown(db.close);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final proxy = NetworkProxy.instance;
      await proxy.initialize(
          saved: jsonEncode(
              SocksProxyConfig(enabled: true, port: server.port).toJson()),
          configureNative: false);
      addTearDown(() => proxy.initialize(saved: '{}', configureNative: false));

      const track =
          MusicMetadata(title: 'Example Song', artist: 'Example Artist');
      var current = true;
      Future<bool> request() async {
        if (search) {
          final results = await searchMusicLyrics(
            trackName: track.title,
            artistName: track.artist,
            albumName: track.album ?? '',
            durationSeconds: 180,
            isCurrent: () => current,
          );
          return results.isEmpty;
        }
        final lyrics = await loadMusicLyrics(track, 180, 'abcdefghijk');
        return lyrics.kind == MusicLyricsKind.unavailable;
      }

      var directAttempts = 0;
      await HttpOverrides.runZoned(() async {
        expect(await request(), isTrue);
        await setLrclibEnabled(true);
        if (search) {
          current = false;
          expect(await request(), isTrue);
          current = true;
        }
        final destination = server.first
            .timeout(const Duration(seconds: 5))
            .then(rejectSocksConnect);
        await Future.wait([
          expectLater(destination, completion(('lrclib.net', 443))),
          expectLater(request(), throwsA(isA<MusicLyricsRequestException>())),
        ]);
      }, findProxyFromEnvironment: (_, __) {
        // Refuse even a default dart:io connection before DNS if routing regresses.
        directAttempts++;
        throw StateError('Unexpected direct connection');
      });
      expect(directAttempts, 0);
    });
  }
}
