import '../music/models/music_track.dart';
import '../videos/models/video.dart';

enum RecommendationDomain { video, music }

enum RecommendationFeedback {
  like,
  save,
  dislike,
  notInterested,
  block,
  unblock,
}

/// Catalog metadata only. Playback URLs, artwork URLs and account credentials
/// never enter the recommendation engine or its durable taste snapshot.
class RecommendationCandidate {
  final String id;
  final Map<String, Object?> data;

  const RecommendationCandidate._(this.id, this.data);

  factory RecommendationCandidate.video(Video video,
      {bool isSubscribed = false}) {
    final id = video.videoId;
    return RecommendationCandidate._(id, {
      'id': id,
      'title': _text(video.title, 1000),
      'author': _text(video.author, 300),
      'authorId': _text(video.authorId, 128),
      'durationSeconds': _seconds(video.lengthSeconds),
      'keywords': video.keywords.take(64).map((s) => _text(s, 100)).toList(),
      'description': _text(video.description, 4000),
      'genre': _text(video.genre, 100),
      'category': _text(video.genre, 100),
      'publishedMs': video.published == null ? null : video.published! * 1000,
      'isLive': video.liveNow == true,
      'isUpcoming': video.isUpcoming == true,
      'viewCount': video.viewCount,
      'likeCount': video.likeCount,
      'isSubscribed': isSubscribed,
    });
  }

  factory RecommendationCandidate.music(MusicTrack track) =>
      RecommendationCandidate.fromMusicVideo(track.toVideo());

  factory RecommendationCandidate.fromMusicVideo(Video video) {
    final metadata = video.musicMetadata;
    final artist = _text(metadata?.artist ?? video.author, 300).trim();
    // An Invidious uploader is not a verified YouTube Music artist entity.
    // Keep the identity's provenance visible and never merge unknown artists.
    final uploader = _text(video.authorId, 128);
    final artistKey = uploader.isNotEmpty
        ? 'uploader:$uploader'
        : artist.isNotEmpty
            ? 'name:${artist.toLowerCase()}'
            : 'track:${video.videoId}';
    return RecommendationCandidate._(video.videoId, {
      'id': video.videoId,
      'title': _text(metadata?.title ?? video.title, 1000),
      'author': artist,
      'authorId': uploader,
      'artist': artist,
      'artistKey': artistKey,
      'durationSeconds': _seconds(video.lengthSeconds),
      // The upload category "Music" is not a musical genre.
      'genre': null,
      'isLive': video.liveNow == true,
    });
  }

  static final _id = RegExp(r'^[A-Za-z0-9_-]{11}$');
  bool get valid => _id.hasMatch(id) && (data['title'] as String).isNotEmpty;

  String get creatorKey =>
      (data['artistKey'] ?? data['authorId'] ?? '') as String;

  static String _text(String? text, int limit) =>
      String.fromCharCodes((text ?? '').runes.take(limit));

  static int? _seconds(int? seconds) =>
      seconds != null && seconds >= 0 && seconds <= 604800 ? seconds : null;
}

class RecommendedItem<T> {
  final T item;
  final double score;
  final String reason;

  const RecommendedItem(this.item, {required this.score, required this.reason});
}

class RecommendationInterest {
  final String id;
  final String label;
  final String? category;
  final List<String> topics;
  final List<String> queries;

  const RecommendationInterest._(
      this.id, this.label, this.category, this.topics, this.queries);

  static RecommendationInterest? _parse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final label = value['label'];
    final category = value['category'];
    final queries = _boundedStrings(value['queries'], 3);
    if (id is! String ||
        id.isEmpty ||
        id.length > 512 ||
        label is! String ||
        label.isEmpty ||
        label.length > 512 ||
        (category != null && (category is! String || category.length > 64)) ||
        queries.isEmpty) {
      return null;
    }
    return RecommendationInterest._(id, label, category as String?,
        _boundedStrings(value['topics'], 5), queries);
  }
}

List<String> _boundedStrings(Object? value, int limit) =>
    List.unmodifiable((value is List ? value : const [])
        .whereType<String>()
        .where((text) => text.trim().isNotEmpty && text.length <= 512)
        .take(limit));

class RecommendationResult<T> {
  final List<RecommendedItem<T>> items;
  final bool available;
  final bool cancelled;
  final String? message;
  final Map<String, dynamic> summary;

  List<RecommendationInterest> get interests {
    final rows = summary['interestChips'];
    return rows is List
        ? List.unmodifiable(rows
            .take(4)
            .map(RecommendationInterest._parse)
            .whereType<RecommendationInterest>())
        : const [];
  }

  List<String> get discoveryQueries =>
      _boundedStrings(summary['discoveryQueries'], 3);

  const RecommendationResult(
      {required this.items,
      required this.available,
      this.cancelled = false,
      this.message,
      this.summary = const {}});

  const RecommendationResult.unavailable([this.message])
      : items = const [],
        available = false,
        cancelled = false,
        summary = const {};

  const RecommendationResult.cancelled()
      : items = const [],
        available = false,
        cancelled = true,
        message = null,
        summary = const {};
}
