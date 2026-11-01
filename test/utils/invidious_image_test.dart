import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const server = Server(url: 'https://instance.example');

  test('Google avatar hosts use the instance image proxy', () {
    for (final url in [
      'https://yt3.googleusercontent.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      'https://yt3.ggpht.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      '//yt3.ggpht.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      'http://YT3.GOOGLEUSERCONTENT.COM/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
    ]) {
      expect(invidiousImageUrl(url, server),
          'https://instance.example/ggpht/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
          reason: url);
    }
  });

  test('thumbnail paths match Invidious routes and preserve query encoding',
      () {
    const paths = {
      '/vi/video-id/maxresdefault.jpg?x=a%2Fb&x=c':
          '/vi/video-id/maxresdefault.jpg?x=a%2Fb&x=c',
      '/vi_webp/video-id/hqdefault.webp': '/vi/video-id/hqdefault.jpg',
      '/s_p/id/image.jpg': '/s_p/id/image.jpg',
      '/pl_c/id/image.jpg': '/pl_c/id/image.jpg',
      '/tvfilm_banner/id/image.jpg': '/tvfilm_banner/id/image.jpg',
    };
    for (final host in ['i.ytimg.com', 'i1.ytimg.com', 'i9.ytimg.com']) {
      for (final entry in paths.entries) {
        expect(invidiousImageUrl('https://$host${entry.key}', server),
            '${server.url}${entry.value}');
      }
    }
  });

  test(
      'relative and proxied images remain on the instance without double proxy',
      () {
    for (final url in [
      '/ggpht/avatar=s88',
      'ggpht/avatar=s88',
      'https://instance.example/ggpht/avatar=s88',
      '//instance.example/ggpht/avatar=s88',
    ]) {
      final resolved = invidiousImageUrl(url, server);
      expect(resolved, 'https://instance.example/ggpht/avatar=s88');
      expect(invidiousImageUrl(resolved, server), resolved);
    }
  });

  test('server path prefixes and ports survive trailing slashes', () {
    for (final base in [
      'http://localhost:8080/invidious',
      'http://localhost:8080/invidious/',
    ]) {
      for (final image in [
        '/ggpht/avatar=s88?x=a%2Fb',
        'https://yt3.ggpht.com/avatar=s88?x=a%2Fb',
      ]) {
        expect(invidiousImageUrl(image, Server(url: base)),
            'http://localhost:8080/invidious/ggpht/avatar=s88?x=a%2Fb');
      }
    }
  });

  test('external providers and lookalike hosts are not rewritten', () {
    for (final url in [
      'https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=id',
      'https://yt3.ggpht.com.evil.example/avatar',
      'https://evil.example/yt3.googleusercontent.com/avatar',
      'https://i.ytimg.com.evil.example/vi/id/default.jpg',
      'https://other-instance.example/ggpht/avatar',
      'file:///offline/thumbnail.jpg',
      '',
      'http://[invalid',
    ]) {
      expect(invidiousImageUrl(url, server), url, reason: url);
    }
    expect(invidiousImageUrl('//cdn.example/image.jpg', server),
        'https://cdn.example/image.jpg');
  });

  test('headers are scoped to the resolved origin', () {
    const authenticated = Server(
      url: 'https://instance.example',
      customHeaders: {'Authorization': 'Basic test'},
    );
    final proxied = invidiousImageUrl(
        'https://yt3.googleusercontent.com/avatar', authenticated);
    expect(authenticated.headersForUrl(proxied), authenticated.customHeaders);
    final external =
        invidiousImageUrl('https://cdn.example/image.jpg', authenticated);
    expect(authenticated.headersForUrl(external), isNull);
  });
}
