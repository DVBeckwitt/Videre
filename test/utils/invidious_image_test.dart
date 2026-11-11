import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/network/gateway_context.dart';
import 'package:clipious/network/nerdvpn_origin.dart';
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
      expect(invidiousImageUrl(url!, server), url);
    }
  });

  test('Google avatar hosts use the instance image proxy', () {
    for (final url in [
      'https://yt3.googleusercontent.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      'https://lh3.googleusercontent.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      '//LH3.GOOGLEUSERCONTENT.COM/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      'https://yt3.ggpht.com/a%2Fb=s176-c-k-c0x00ffffff-no-rj',
      'https://YT3.GGPHT.COM./a%2Fb=s176-c-k-c0x00ffffff-no-rj',
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
      expect(invidiousImageUrl(resolved!, server), resolved);
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

  test('NerdVPN video thumbnails stay on the selected onion account', () {
    const public = 'https://invidious.nerdvpn.de';
    const onion = 'http://$nerdVpnOnionHost';
    const path = '/vi/M7lc1UVf-VE/mqdefault.jpg';
    const query = '?sig=a%2fb%2Bc&x=one&x=two&empty=';
    for (final (source, destination) in [
      (public, onion),
      (public, 'https://$nerdVpnOnionHost/'),
      (onion, 'https://$nerdVpnOnionHost'),
    ]) {
      final selected = Server(
          url: destination, customHeaders: const {'X-Test': 'onion-account'});
      final resolved = invidiousImageUrl('$source$path$query', selected);
      expect(resolved, '${Uri.parse(destination).origin}$path$query');
      expect(selected.headersForUrl('$source$path$query'), isNull);
      expect(selected.headersForUrl(resolved!),
          containsPair('X-Test', 'onion-account'));
      expect(invidiousImageUrl(resolved, selected), resolved);
    }
  });

  test('NerdVPN thumbnail rebasing admits only exact origins and root vi paths',
      () {
    const public = 'https://invidious.nerdvpn.de';
    const onion = 'http://$nerdVpnOnionHost';
    const path = '/vi/M7lc1UVf-VE/mqdefault.jpg';
    const selected = Server(url: onion);
    for (final url in [
      'https://invidious.nerdvpn.de.example$path',
      'https://user@invidious.nerdvpn.de$path',
      'https://@invidious.nerdvpn.de$path',
      r'https://invidious.nerdvpn.de\vi\M7lc1UVf-VE\mqdefault.jpg',
      'https://invidious.nerdvpn.de:8443$path',
      'http://invidious.nerdvpn.de$path',
      'http://$nerdVpnOnionHost:8080$path',
      '$public/prefix$path',
      '$public/vi/../vi/M7lc1UVf-VE/mqdefault.jpg',
      '$public/vi/%2e%2e/vi/M7lc1UVf-VE/mqdefault.jpg',
      '$public/vi/M7lc1UVf-VE/%2e%2e%2fadmin.jpg',
      '$public/vi/short-id/mqdefault.jpg',
      '$public/vi/M7lc1UVf-VE/mqdefault.webp',
      '$public/ggpht/avatar',
      '$public/login',
      'https://dearrow-thumb.ajay.app$path',
    ]) {
      expect(invidiousImageUrl(url, selected), url, reason: url);
    }
    for (final destination in [
      'https://other.example',
      '$onion/invidious',
      '$onion?account=other',
      '$onion#fragment',
      'http://user@$nerdVpnOnionHost',
      'http://$nerdVpnOnionHost:8080',
    ]) {
      expect(invidiousImageUrl('$public$path', Server(url: destination)),
          '$public$path',
          reason: destination);
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

  test('unsupported official artwork never falls back to a direct URL', () {
    for (final url in [
      'https://i.ytimg.com/an_webp/video/mqdefault_6s.webp',
      'https://s.ytimg.com/yts/img/image.png',
      'https://yt4.ggpht.com/avatar',
      '//lh4.googleusercontent.com/avatar',
      'https://www.youtube.com/img/image.png',
      'https://www.youtube-nocookie.com/img/image.png',
      'https://rr1.googlevideo.com/image.png',
      'https://www.gstatic.com/youtube/img/branding/youtubelogo.svg',
      'https://www.googleapis.com/youtube/v3/image',
      'https://i.ytimg.com./unsupported/image.png',
      'ftp://i.ytimg.com/vi/video/default.jpg',
    ]) {
      expect(invidiousImageUrl(url, server), isNull, reason: url);
    }
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
      expect(authenticated.headersForUrl(proxied!), {
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
    expect(authenticated.headersForUrl(external!), isNull);
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
