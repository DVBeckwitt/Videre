import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/utils/invidious_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const server = Server(url: 'https://instance.example');

  test('storyboards use the instance proxy and preserve signatures', () {
    for (final host in ['i.ytimg.com', 'i1.ytimg.com']) {
      final url = invidiousImageUrl(
          'https://$host/sb/video/L2/M1.jpg?sigh=a%2Fb&x=1', server);
      expect(url,
          'https://instance.example/sb/${host.split('.').first}/video/L2/M1.jpg?sigh=a%2Fb&x=1');
      expect(invidiousImageUrl(url, server), url);
    }
  });

  test('Google avatar hosts use the instance image proxy', () {
    for (final url in [
      'https://yt3.googleusercontent.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      'https://lh3.googleusercontent.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      '//LH3.GOOGLEUSERCONTENT.COM/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
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
      'https://lh3.googleusercontent.com.evil.example/avatar',
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
    for (final host in [
      'yt3.googleusercontent.com',
      'lh3.googleusercontent.com'
    ]) {
      final direct = 'https://$host/avatar';
      final proxied = invidiousImageUrl(direct, authenticated);
      expect(authenticated.headersForUrl(direct), isNull);
      expect(authenticated.headersForUrl(proxied), {
        ...authenticated.customHeaders,
        gatewayContextHeader: GatewayRequestContext.forAccount(
                authenticated.profileId,
                authenticated.accountId,
                authenticated.url)!
            .encoded,
      });
    }
    final external =
        invidiousImageUrl('https://cdn.example/image.jpg', authenticated);
    expect(authenticated.headersForUrl(external), isNull);
  });

  test('instance image caches are isolated by person and account', () {
    const url = 'https://instance.example/thumbnail.jpg';
    const alice = Server(
        url: 'https://instance.example', profileId: 'alice', id: 'account-a');
    final bob = alice.copyWith(profileId: 'bob');
    final otherAccount = alice.copyWith(id: 'account-b');
    final key = invidiousImageCacheKey(url, alice);
    expect(key, startsWith('videre-account-image:'));
    expect(invidiousImageCacheKey(url, alice), key);
    expect(invidiousImageCacheKey(url, bob), isNot(key));
    expect(invidiousImageCacheKey(url, otherAccount), isNot(key));
    expect(key, isNot(contains('alice')));
    const external = 'https://images.example/thumbnail.jpg';
    expect(invidiousImageCacheKey(external, alice), external);
    expect(invidiousImageCacheKey(external, bob), external);
  });
}
