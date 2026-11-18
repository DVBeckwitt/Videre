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

  test('Shorts use the instance watch route and keep only the timestamp', () {
    expect(
        links.rewriteText(
            'Short: (https://m.youtube.com/shorts/dQw4w9WgXcQ?si=tracking&t=28).'),
        'Short: (https://instance.example:8443/iv/watch?v=dQw4w9WgXcQ&t=28).');
  });

  test('live, embedded, music browse and searches retain only instance URLs',
      () {
    const origin = 'https://instance.example:8443/iv';
    expect(
        links.rewriteText(
            'https://youtube.com/live/dQw4w9WgXcQ?start=12 https://youtube.com/embed/dQw4w9WgXcQ#t=30'),
        '$origin/watch?v=dQw4w9WgXcQ&t=12 $origin/watch?v=dQw4w9WgXcQ&t=30');
    expect(
        links.rewriteText(
            'https://music.youtube.com/browse/VLPLmusic https://youtube.com/results?search_query=quiet%20piano'),
        '$origin/playlist?list=PLmusic $origin/search?q=quiet+piano');
    expect(links.rewriteText('https://youtube.com/@example?si=private'),
        '[Unavailable]');
  });

  test('a missing or invalid instance cannot put a direct URL into the text',
      () {
    for (final server in [null, const Server(url: 'https://youtube.com')]) {
      final linkifier = InvidiousLinkifier(server, '[Unavailable]');
      expect(linkifier.rewriteText('https://youtu.be/dQw4w9WgXcQ'),
          '[Unavailable]');
    }
  });

  test('bad URL encoding cannot break a description or disclose the address',
      () {
    expect(
        links.rewriteText(
            'See https://youtu.be/%FF https://www.youtube.com/watch?v=%FF'),
        'See [Unavailable] [Unavailable]');
  });
}
