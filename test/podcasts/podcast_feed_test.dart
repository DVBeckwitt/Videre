import 'dart:convert';

import 'package:clipious/podcasts/models/podcast.dart';
import 'package:clipious/podcasts/services/podcast_feed_service.dart';
import 'package:clipious/podcasts/services/podcast_http.dart';
import 'package:flutter_test/flutter_test.dart';

String _feed(String items) => '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
 xmlns:details="http://purl.org/rss/1.0/modules/content/" xmlns:other="urn:other">
<channel><title>Local podcast</title><description>Publisher &amp; friends</description>
<itunes:author>Host</itunes:author>$items</channel></rss>''';

String _episode(
        {String guid = 'episode-one',
        String url = '/one.mp3',
        String title = 'Episode one',
        String extra = '',
        String type = 'audio/mpeg'}) =>
    '<item><title>$title</title><guid>$guid</guid>'
    '<enclosure url="$url" type="$type" length="12345"/>$extra</item>';

void main() {
  final source = Uri.parse('https://publisher.example/feed.xml?private=token');
  PodcastFeed parse(String body) => PodcastFeedParser.parse(body,
      feedUrl: source, fetchedAt: DateTime.utc(2026, 11, 15));

  test(
      'RSS reads text, enclosure, iTunes duration and numeric publication zone',
      () {
    final feed = parse(_feed(_episode(
        extra: '<itunes:duration>1:02:03</itunes:duration>'
            '<pubDate>Sun, 15 Nov 2026 10:30:00 -0500</pubDate>'
            '<description><![CDATA[<b>Notes</b><script>ignored()</script> &amp; more]]></description>')));
    final episode = feed.episodes.single;
    expect(feed.title, 'Local podcast');
    expect(feed.author, 'Host');
    expect(feed.description, 'Publisher & friends');
    expect(episode.title, 'Episode one');
    expect(episode.mediaUrl, 'https://publisher.example/one.mp3');
    expect(episode.durationSeconds, 3723);
    expect(episode.lengthBytes, 12345);
    expect(episode.publishedAt, DateTime.utc(2026, 11, 15, 15, 30));
    expect(episode.description, 'Notes & more');
    expect(feed.updatedAt, DateTime.utc(2026, 11, 15));
    expect(feed.toJson(), isNot(contains('artwork')));
  });

  test('episode notes prefer RSS description and fall back by namespace', () {
    final feed = parse(_feed(_episode(
            extra: '<description>RSS notes</description>'
                '<details:encoded>More details</details:encoded>'
                '<itunes:summary>Short summary</itunes:summary>') +
        _episode(
            guid: 'fallback',
            extra:
                '<description><![CDATA[<script>Skip</script>]]></description>'
                '<details:encoded><![CDATA[<p>First &amp; second</p>'
                '<p>Third<br>fourth <a href="https://publisher.example/secret">link</a>'
                '<iframe src="https://publisher.example/embed">Ignore</iframe></p>]]></details:encoded>'
                '<itunes:summary>Short summary</itunes:summary>') +
        _episode(
            guid: 'summary',
            extra: '<other:encoded>Wrong namespace</other:encoded>'
                '<itunes:summary>Short summary</itunes:summary>')));
    expect(feed.episodes.map((episode) => episode.description), [
      'RSS notes',
      'First & second Third fourth link',
      'Short summary',
    ]);
  });

  test('literal markup in episode notes remains plain text and size bounded',
      () {
    final feed = parse(_feed(_episode(
                extra: '<description><p>First</p><p>Second '
                    '<script>Remove this</script><style>Hide this</style>'
                    '<b>sentence</b></p></description>') +
            _episode(
                guid: 'long',
                extra: '<description>${'😀' * 4097}</description>'))
        .replaceFirst('<description>Publisher &amp; friends</description>',
            '<description><p>Publisher</p><script>Ignore</script><p>News</p></description>'));
    expect(feed.description, 'Publisher News');
    expect(feed.episodes.first.description, 'First Second sentence');
    expect(feed.episodes.last.description, '😀' * 4096);
  });

  test('deep literal notes do not prevent the feed opening', () {
    const depth = 25000;
    final feed = parse(_feed(_episode(
        extra: '<description>${'<p>' * depth}Preserved &lt; sample'
            '${'</p>' * depth}</description>')));
    expect(feed.episodes.single.description, 'Preserved < sample');
  });

  test('stable GUID retains identity when title and media URL change', () {
    final original = parse(_feed(_episode()));
    final updated =
        parse(_feed(_episode(title: 'Corrected', url: '/fresh.mp3')));
    expect(updated.id, original.id);
    expect(updated.episodes.single.id, original.episodes.single.id);
    expect(updated.episodes.single.mediaUrl, endsWith('/fresh.mp3'));
  });

  test('enclosure URL supplies stable identity without GUID', () {
    final first = parse(_feed(_episode(guid: '')));
    final second = parse(_feed(_episode(guid: '', title: 'New title')));
    expect(first.episodes.single.id, second.episodes.single.id);
    final different = parse(_feed(_episode(guid: '', url: '/two.mp3')));
    expect(first.episodes.single.id, isNot(different.episodes.single.id));
  });

  test('duplicate GUIDs keep first source occurrence', () {
    final feed = parse(_feed(_episode() +
        _episode(title: 'Duplicate') +
        _episode(guid: 'second', title: 'Second')));
    expect(
        feed.episodes.map((entry) => entry.title), ['Episode one', 'Second']);
  });

  test('redirect base resolves relative audio while source owns feed identity',
      () {
    final feed = PodcastFeedParser.parse(_feed(_episode()),
        feedUrl: source,
        documentUrl: Uri.parse('https://cdn.example/rss/current.xml'));
    expect(feed.feedUrl, source.toString());
    expect(feed.episodes.single.mediaUrl, 'https://cdn.example/one.mp3');
    expect(feed.id, parse(_feed(_episode())).id);
  });

  test(
      'video, invalid and blocked enclosures are skipped without losing good audio',
      () {
    final feed = parse(_feed(_episode(guid: 'video', type: 'video/mp4') +
        _episode(guid: 'youtube', url: 'https://youtube.com/audio.mp3') +
        _episode(guid: 'google', url: 'https://storage.googleapis.com/a.mp3') +
        _episode(
            guid: 'feedburner', url: 'https://feeds.feedburner.com/a.mp3') +
        _episode(
            guid: 'login', url: 'https://user:secret@publisher.example/a.mp3') +
        _episode(guid: 'file', url: 'file:///tmp/audio.mp3') +
        _episode()));
    expect(feed.episodes, hasLength(1));
    expect(feed.episodes.single.title, 'Episode one');
  });

  test('missing optional metadata is safe and an empty valid feed is accepted',
      () {
    final feed = parse(_feed(_episode(
        title: '',
        extra: '<itunes:duration>bad</itunes:duration>'
            '<pubDate>bad</pubDate>')));
    expect(feed.episodes.single.title, 'Untitled episode');
    expect(feed.episodes.single.durationSeconds, isNull);
    expect(feed.episodes.single.publishedAt, isNull);
    expect(parse(_feed('')).episodes, isEmpty);
  });

  test('malformed XML, HTML and document entities are rejected', () {
    for (final text in [
      '<rss><channel>',
      '<html><title>Page</title></html>',
      '<!DOCTYPE rss [<!ENTITY token SYSTEM "https://google.com/secret">]>'
          '<rss><channel><title>&token;</title></channel></rss>'
    ]) {
      expect(() => parse(text), throwsFormatException);
    }
  });

  test('feed byte bound uses UTF-8 and episode list is bounded', () {
    expect(() => parse('é' * (podcastFeedMaximumBytes ~/ 2 + 1)),
        throwsFormatException);
    final feed = parse(
        _feed([for (var i = 0; i < 1003; i++) _episode(guid: '$i')].join()));
    expect(feed.episodes, hasLength(podcastFeedMaximumEpisodes));
  });

  test('model round trip retains metadata without accepting unsafe URLs', () {
    final feed = parse(_feed(_episode()));
    expect(
        PodcastFeed.tryParse(jsonDecode(jsonEncode(feed.toJson())))?.toJson(),
        feed.toJson());
    final invalid = {
      ...feed.episodes.single.toJson(),
      'mediaUrl': 'https://youtu.be/one'
    };
    expect(PodcastEpisode.tryParse(invalid), isNull);
    expect(
        PodcastFeed.tryParse(
            {...feed.toJson(), 'feedUrl': 'https://google.com/rss'}),
        isNull);
    expect(
        PodcastEpisode.tryParse(
            {...feed.episodes.single.toJson(), 'id': '../path'}),
        isNull);
  });

  test(
      'URL policy blocks Google variants and credentials without leaking inputs',
      () {
    for (final link in [
      'https://youtube.com/rss',
      'https://google.co.uk/rss',
      'https://youtube.com./rss',
      'https://feeds.feedburner.com/rss',
      'https://user:private-token@publisher.example/feed',
      'file:///feed.xml',
      'https://publisher.example/feed#fragment',
      'https://[private-token'
    ]) {
      try {
        PodcastUrlPolicy.parse(link);
        fail('Expected blocked URL');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private-token')));
      }
    }
    expect(PodcastUrlPolicy.parse(' HTTPS://Publisher.Example ').toString(),
        'https://publisher.example/');
    expect(
        PodcastUrlPolicy.parse('https://youtube.com.publisher.example/feed')
            .host,
        'youtube.com.publisher.example');
  });
}
