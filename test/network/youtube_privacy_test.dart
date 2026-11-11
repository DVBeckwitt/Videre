import 'package:clipious/network/youtube_privacy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('official service, media and image host families are blocked', () {
    for (final host in [
      'youtube.com',
      'MUSIC.YOUTUBE.COM.',
      'youtu.be',
      'www.youtube-nocookie.com',
      'www.youtubeeducation.com',
      'www.youtubekids.com',
      'yt.be',
      'about.youtube',
      'blog.youtube',
      'youtube\u3002com',
      'music\uff0eyoutube\uff61com.',
      'youtubei.googleapis.com',
      'youtube.googleapis.com',
      'rr1---sn-example.googlevideo.com',
      'i.ytimg.com',
      's.ytimg.com',
      'yt3.ggpht.com',
      'lh3.googleusercontent.com',
      'www.gstatic.com',
    ]) {
      expect(isOfficialYoutubeHost(host), isTrue, reason: host);
    }
  });

  test('matches actual destinations rather than substrings or signed queries',
      () {
    for (final host in [
      'invidious.nerdvpn.de',
      'invidious.dvbeckwitt.duckdns.org',
      'notyoutube.com',
      'youtube.com.example.org',
      '127.0.0.1',
      'sponsor.ajay.app',
    ]) {
      expect(isOfficialYoutubeHost(host), isFalse, reason: host);
    }
    final proxy = Uri.parse(
        'https://invidious.example/videoplayback?host=rr1.googlevideo.com');
    expect(isOfficialYoutubeHost(proxy.host), isFalse);
  });

  test('shared Google API hosts cannot dispatch YouTube through other paths',
      () {
    for (final url in [
      'https://www.googleapis.com/youtube/v3/videos',
      'https://www.googleapis.com/upload/youtube/v3/videos',
      'https://content.googleapis.com/youtube/v3/videos',
      'https://www.googleapis.com/youtubeAnalytics/v2/reports',
      'https://www.googleapis.com/youtube%2fv3/search',
      'https://content.googleapis.com/youtube%2Fv3/search',
      'https://www.googleapis.com/batch',
      'https://content.googleapis.com/batch',
      'https://www.googleapis.com/drive/v3/files',
      'https://www.googleapis.com/drive%2fv3/files',
    ]) {
      expect(isOfficialYoutubeUrl(Uri.parse(url)), isTrue, reason: url);
    }
  });

  test('official Music API path is blocked regardless of API parameters', () {
    final url = Uri.parse('https://music.youtube.com/youtubei/v1/search');
    expect(isOfficialYoutubeUrl(url), isTrue);
    expect(
        isOfficialYoutubeUrl(url.replace(query: 'prettyPrint=false')), isTrue);
  });
}
