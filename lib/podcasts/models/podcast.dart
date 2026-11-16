import '../services/podcast_url.dart';

class PodcastEpisode {
  final String id;
  final String title;
  final String mediaUrl;
  final String mimeType;
  final String description;
  final int? durationSeconds;
  final int? lengthBytes;
  final DateTime? publishedAt;

  const PodcastEpisode({
    required this.id,
    required this.title,
    required this.mediaUrl,
    required this.mimeType,
    this.description = '',
    this.durationSeconds,
    this.lengthBytes,
    this.publishedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'mediaUrl': mediaUrl,
        'mimeType': mimeType,
        'description': description,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        if (lengthBytes != null) 'lengthBytes': lengthBytes,
        if (publishedAt != null) 'publishedAt': publishedAt!.toIso8601String(),
      };

  static PodcastEpisode? tryParse(Object? value) {
    if (value is! Map || !_validId(value['id'])) return null;
    final title = podcastText(value['title'], limit: 512);
    final url = _url(value['mediaUrl']);
    final mime = value['mimeType'];
    if (title.isEmpty || url == null || mime is! String || !isAudioMime(mime)) {
      return null;
    }
    return PodcastEpisode(
        id: value['id'] as String,
        title: title,
        mediaUrl: url,
        mimeType: mime.toLowerCase(),
        description: podcastText(value['description'], limit: 4096),
        durationSeconds: _positive(value['durationSeconds'], 7 * 86400),
        lengthBytes: _positive(value['lengthBytes'], 2 * 1024 * 1024 * 1024),
        publishedAt: _date(value['publishedAt']));
  }

  static bool isAudioMime(String value) => const {
        'audio/mpeg',
        'audio/mp3',
        'audio/mp4',
        'audio/m4a',
        'audio/x-m4a',
        'audio/aac',
        'audio/aacp',
        'audio/ogg',
        'audio/opus',
        'audio/webm',
        'audio/wav',
        'audio/x-wav',
        'audio/flac',
        'audio/x-flac',
      }.contains(value.toLowerCase().split(';').first.trim());
}

class PodcastFeed {
  final String id;
  final String feedUrl;
  final String title;
  final String description;
  final String author;
  final List<PodcastEpisode> episodes;
  final DateTime? updatedAt;

  const PodcastFeed({
    required this.id,
    required this.feedUrl,
    required this.title,
    required this.episodes,
    this.description = '',
    this.author = '',
    this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'feedUrl': feedUrl,
        'title': title,
        'description': description,
        'author': author,
        'episodes': episodes.map((episode) => episode.toJson()).toList(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  static PodcastFeed? tryParse(Object? value) {
    if (value is! Map || !_validId(value['id'])) return null;
    final url = _url(value['feedUrl']);
    final title = podcastText(value['title'], limit: 512);
    final rows = value['episodes'];
    if (url == null || title.isEmpty || rows is! List || rows.length > 1000) {
      return null;
    }
    final episodes = <String, PodcastEpisode>{};
    for (final row in rows) {
      final episode = PodcastEpisode.tryParse(row);
      if (episode != null) episodes.putIfAbsent(episode.id, () => episode);
    }
    return PodcastFeed(
        id: value['id'] as String,
        feedUrl: url,
        title: title,
        description: podcastText(value['description'], limit: 4096),
        author: podcastText(value['author'], limit: 512),
        episodes: List.unmodifiable(episodes.values),
        updatedAt: _date(value['updatedAt']));
  }
}

String podcastText(Object? value, {required int limit}) => value is String
    ? String.fromCharCodes(value
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim()
        .runes
        .take(limit))
    : '';

bool _validId(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').stringMatch(value) == value;

String? _url(Object? value) {
  if (value is! String) return null;
  try {
    return PodcastUrlPolicy.parse(value).toString();
  } catch (_) {
    return null;
  }
}

int? _positive(Object? value, int maximum) =>
    value is int && value > 0 && value <= maximum ? value : null;

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
