import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:xml/xml.dart';

import '../models/podcast.dart';
import 'podcast_http.dart';

const podcastFeedMaximumBytes = 4 * 1024 * 1024;
const podcastFeedMaximumEpisodes = 1000;
const _contentNamespace = 'http://purl.org/rss/1.0/modules/content/';
const _itunesNamespace = 'http://www.itunes.com/dtds/podcast-1.0.dtd';
const _descriptionSourceLimit = 65536;
const _hiddenDescriptionTags = {
  'embed',
  'iframe',
  'noscript',
  'object',
  'script',
  'style',
  'template',
};
const _descriptionBreakTags = {
  'blockquote',
  'br',
  'dd',
  'div',
  'dt',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hr',
  'li',
  'p',
  'pre',
  'td',
  'th',
};

/// A fresh credential-free publisher client is owned by each fetch. The app's
/// Invidious Service is intentionally not involved in RSS subscriptions.
class PodcastFeedService {
  final http.Client Function() _createClient;
  final Duration timeout;

  PodcastFeedService({
    http.Client Function()? createClient,
    this.timeout = const Duration(seconds: 30),
  }) : _createClient =
            createClient ?? (() => IOClient(createPodcastHttpClient()));

  Future<PodcastFeed> fetch(String link) async {
    final source = PodcastUrlPolicy.parse(link);
    final client = _createClient();
    try {
      return await _fetch(client, source).timeout(timeout);
    } on FormatException {
      rethrow;
    } catch (_) {
      // Private feed URLs may contain tokens. Never expose transport exception
      // text, redirect targets, or response bodies in UI errors or logs.
      throw const FormatException(
          'Could not load this podcast feed. Try again.');
    } finally {
      client.close();
    }
  }

  Future<PodcastFeed> _fetch(http.Client client, Uri source) async {
    var current = source;
    final visited = <Uri>{};
    for (var redirects = 0; redirects <= 5; redirects++) {
      PodcastUrlPolicy.validate(current);
      if (!visited.add(current)) {
        throw const FormatException('The podcast feed redirects in a loop.');
      }
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers['Accept'] = 'application/rss+xml, application/xml, text/xml';
      final response = await client.send(request);
      if (const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        await response.stream.listen(null).cancel();
        final location = response.headers['location'];
        if (location == null || redirects == 5) {
          throw const FormatException(
              'The podcast feed has too many redirects.');
        }
        try {
          current = PodcastUrlPolicy.validate(current.resolve(location));
        } catch (_) {
          throw const FormatException(
              'The podcast feed redirects to a blocked or invalid address.');
        }
        continue;
      }
      if (response.statusCode != 200) {
        await response.stream.listen(null).cancel();
        throw const FormatException(
            'The publisher could not provide this podcast feed.');
      }
      if ((response.contentLength ?? 0) > podcastFeedMaximumBytes) {
        await response.stream.listen(null).cancel();
        throw const FormatException('This podcast feed exceeds 4 MiB.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > podcastFeedMaximumBytes) {
          throw const FormatException('This podcast feed exceeds 4 MiB.');
        }
        bytes.add(chunk);
      }
      String text;
      try {
        text = utf8.decode(bytes.takeBytes());
      } catch (_) {
        throw const FormatException('The podcast feed must use UTF-8 text.');
      }
      return compute(_parseFeed, (
        text,
        source.toString(),
        current.toString(),
        DateTime.now().toUtc()
      ));
    }
    throw const FormatException('The podcast feed has too many redirects.');
  }
}

PodcastFeed _parseFeed((String, String, String, DateTime) input) =>
    PodcastFeedParser.parse(input.$1,
        feedUrl: Uri.parse(input.$2),
        documentUrl: Uri.parse(input.$3),
        fetchedAt: input.$4);

class PodcastFeedParser {
  static PodcastFeed parse(String source,
      {required Uri feedUrl, Uri? documentUrl, DateTime? fetchedAt}) {
    feedUrl = PodcastUrlPolicy.validate(feedUrl);
    final base = PodcastUrlPolicy.validate(documentUrl ?? feedUrl);
    if (source.length > podcastFeedMaximumBytes ||
        utf8.encode(source).length > podcastFeedMaximumBytes) {
      throw const FormatException('This podcast feed exceeds 4 MiB.');
    }
    if (RegExp(r'<!\s*(?:DOCTYPE|ENTITY)', caseSensitive: false)
        .hasMatch(source)) {
      throw const FormatException(
          'Podcast feeds with document entities are not supported.');
    }
    late XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } catch (_) {
      throw const FormatException(
          'This link does not contain a valid RSS feed.');
    }
    final root = document.rootElement;
    final channel = root.name.local == 'rss' ? _child(root, 'channel') : null;
    if (channel == null) {
      throw const FormatException('Choose an RSS podcast feed link.');
    }
    final title = _text(_child(channel, 'title'), 512);
    if (title.isEmpty) {
      throw const FormatException('The podcast feed is missing its title.');
    }
    final feedId = _hash(feedUrl.toString());
    final episodes = <String, PodcastEpisode>{};
    for (final item
        in channel.childElements.where((node) => node.name.local == 'item')) {
      if (episodes.length >= podcastFeedMaximumEpisodes) break;
      PodcastEpisode? episode;
      for (final enclosure in item.childElements
          .where((node) => node.name.local == 'enclosure')) {
        final rawUrl = enclosure.getAttribute('url');
        final mime = (enclosure.getAttribute('type') ?? '')
            .toLowerCase()
            .split(';')
            .first
            .trim();
        if (rawUrl == null || !PodcastEpisode.isAudioMime(mime)) continue;
        Uri media;
        try {
          media = PodcastUrlPolicy.validate(base.resolve(rawUrl.trim()));
        } catch (_) {
          continue;
        }
        final guid = podcastText(_child(item, 'guid')?.innerText, limit: 4096);
        final id = _hash('$feedId\n${guid.isEmpty ? media : guid}');
        final name = _text(_child(item, 'title'), 512);
        final length = int.tryParse(enclosure.getAttribute('length') ?? '');
        episode = PodcastEpisode(
            id: id,
            title: name.isEmpty ? 'Untitled episode' : name,
            mediaUrl: media.toString(),
            mimeType: mime,
            description: _episodeDescription(item),
            durationSeconds: _duration(_child(item, 'duration')?.innerText),
            lengthBytes:
                length != null && length > 0 && length <= 2 * 1024 * 1024 * 1024
                    ? length
                    : null,
            publishedAt: _published(_child(item, 'pubDate')?.innerText));
        break;
      }
      if (episode != null) episodes.putIfAbsent(episode.id, () => episode!);
    }
    return PodcastFeed(
        id: feedId,
        feedUrl: feedUrl.toString(),
        title: title,
        description: _descriptionText(_child(channel, 'description')),
        author: _text(
            _child(channel, 'author') ?? _child(channel, 'managingEditor'),
            512),
        episodes: List.unmodifiable(episodes.values),
        updatedAt: fetchedAt ?? DateTime.now().toUtc());
  }

  static XmlElement? _child(XmlElement node, String name) =>
      node.childElements.where((child) => child.name.local == name).firstOrNull;

  static String _episodeDescription(XmlElement item) {
    for (final element in [
      item.getElement('description') ?? _child(item, 'description'),
      item.getElement('encoded', namespace: _contentNamespace),
      item.getElement('summary', namespace: _itunesNamespace),
    ]) {
      final text = _descriptionText(element);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String _descriptionText(XmlElement? element) {
    if (element == null) return '';
    final fragment = html.parseFragment(_boundedDescriptionMarkup(element));
    final buffer = StringBuffer();
    final space = dom.Text(' ');
    final pending = fragment.nodes.reversed.toList();
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is dom.Text) {
        buffer.write(node.data);
      } else if (node is dom.Element) {
        final name = node.localName?.split(':').last;
        if (_hiddenDescriptionTags.contains(name)) continue;
        if (_descriptionBreakTags.contains(name)) {
          buffer.write(' ');
          pending.add(space);
        }
        pending.addAll(node.nodes.reversed);
      }
    }
    return podcastText(buffer.toString().replaceAll(RegExp(r'\s+'), ' '),
        limit: 4096);
  }

  /// Flatten literal XML iteratively. Recursive serialization can overflow
  /// the stack on a deeply nested description before any size limit applies.
  static String _boundedDescriptionMarkup(XmlElement element) {
    final result = StringBuffer();
    final separator = XmlText(' ');
    final pending = element.children.reversed.toList();
    while (pending.isNotEmpty && result.length < _descriptionSourceLimit) {
      final node = pending.removeLast();
      if (node is XmlElement) {
        final name = node.name.local.toLowerCase();
        if (_hiddenDescriptionTags.contains(name)) continue;
        if (_descriptionBreakTags.contains(name)) {
          result.write(' ');
          pending.add(separator);
        }
        pending.addAll(node.children.reversed);
      } else if (node is XmlText || node is XmlCDATA) {
        final remaining = _descriptionSourceLimit - result.length;
        var text = _descriptionPrefix(node.value ?? '', remaining);
        if (node is XmlText && node.parent != null && node.parent != element) {
          // Within literal XML markup, preserve escaped text as text when
          // the combined RSS description is parsed as HTML below.
          text = const HtmlEscape(HtmlEscapeMode.element).convert(text);
        }
        result.write(_descriptionPrefix(text, remaining));
      }
    }
    return result.toString();
  }

  static String _descriptionPrefix(String text, int limit) {
    if (text.length <= limit) return text;
    if (limit > 0) {
      final last = text.codeUnitAt(limit - 1);
      if (last >= 0xd800 && last <= 0xdbff) limit--;
    }
    return text.substring(0, limit);
  }

  static String _text(XmlElement? element, int limit) {
    if (element == null) return '';
    final value = element.innerText;
    final fragment = html.parseFragment(
        value.length > 65536 ? value.substring(0, 65536) : value);
    for (final node in fragment.querySelectorAll('script,style')) {
      node.remove();
    }
    return podcastText(fragment.text, limit: limit);
  }

  static int? _duration(String? value) {
    if (value == null) return null;
    final parts = value.trim().split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    var seconds = 0;
    for (final part in parts) {
      final count = int.tryParse(part);
      if (count == null || count < 0) return null;
      seconds = seconds * 60 + count;
    }
    return seconds > 0 && seconds <= 7 * 86400 ? seconds : null;
  }

  static DateTime? _published(String? value) {
    if (value == null) return null;
    try {
      final text = value.trim();
      final iso = DateTime.tryParse(text);
      if (iso != null) return iso.toUtc();
      final zone = RegExp(r' ([+-])(\d{2})(\d{2})$').firstMatch(text);
      if (zone != null) {
        final hours = int.parse(zone[2]!);
        final minutes = int.parse(zone[3]!);
        if (hours > 23 || minutes > 59) return null;
        final utc = HttpDate.parse('${text.substring(0, zone.start)} GMT');
        final offset = Duration(minutes: hours * 60 + minutes);
        return zone[1] == '+' ? utc.subtract(offset) : utc.add(offset);
      }
      return HttpDate.parse(text).toUtc();
    } catch (_) {
      return null;
    }
  }

  static String _hash(String input) =>
      sha256.convert(utf8.encode(input)).toString();
}
