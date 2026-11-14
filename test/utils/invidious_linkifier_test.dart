import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/models/invidious_linkifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const links = InvidiousLinkifier(
      Server(url: 'https://instance.example:8443/iv'), '[Unavailable]');

  test('canonicalizes supported addresses and preserves the surrounding text',
      () {
    const origin = 'https://instance.example:8443/iv';
    expect(
        links.rewriteText(
            'Watch youtu.be/dQw4w9WgXcQ?t=90. Playlist: https://www.youtube.com/playlist?list=PL_123&si=tracking'),
        'Watch $origin/watch?v=dQw4w9WgXcQ&t=90. Playlist: $origin/playlist?list=PL_123');
    expect(
        links.rewriteText(
            '//www.youtube.com/channel/UC_kRDKYrUlrbtrSiyu5Tflg https://music.youtube.com/playlist?list=VLPLmusic'),
        '$origin/channel/UC_kRDKYrUlrbtrSiyu5Tflg $origin/playlist?list=PLmusic');
  });

  test('unsupported official URLs are omitted without changing other links',
      () {
    expect(
        links.rewriteText(
            'See https://youtube.com/redirect?q=private https://example.org/watch.'),
        'See [Unavailable] https://example.org/watch.');
    expect(links.rewriteText('youtube.com, www.youtube.co.uk, and yt.be.'),
        '[Unavailable], [Unavailable], and [Unavailable].');
    expect(links.rewriteText('See https://notyoutube.com/ for details.'),
        'See https://notyoutube.com/ for details.');
  });

  test('a missing or invalid instance cannot put a direct URL into the text',
      () {
    for (final server in [null, const Server(url: 'https://youtube.com')]) {
      final linkifier = InvidiousLinkifier(server, '[Unavailable]');
      expect(linkifier.rewriteText('https://youtu.be/dQw4w9WgXcQ'),
          '[Unavailable]');
    }
  });
}
