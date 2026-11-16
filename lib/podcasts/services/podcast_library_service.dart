import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../settings/models/db/settings.dart';
import '../../utils/interfaces/db.dart';
import '../models/podcast.dart';
import 'podcast_feed_service.dart';
import 'podcast_http.dart';

const podcastLibrarySettingName = 'podcast-library-v1';
const podcastLibraryMaximumBytes = 10 * 1024 * 1024;
const podcastLibraryMaximumFeeds = 100;

class _PodcastChanges extends ChangeNotifier {
  Future<void> writes = Future.value();
  final operations = <String, int>{};
  String? stored;
  List<PodcastFeed> feeds = const [];

  void changed() => notifyListeners();
}

/// Subscriptions and cached episode descriptions belong only to this person.
/// Reads are local; contacting a publisher requires an explicit add or refresh.
class PodcastLibraryService {
  static final _owners = Expando<Map<String, _PodcastChanges>>();
  final IDbClient _database;
  final _PodcastChanges _changes;
  final PodcastFeedService _feedService;

  PodcastLibraryService.forProfile(IDbClient database, String profileId,
      {PodcastFeedService? feedService})
      : _database = database.forProfile(profileId),
        _changes = (_owners[database] ??= {})
            .putIfAbsent(profileId, _PodcastChanges.new),
        _feedService = feedService ?? PodcastFeedService();

  String get profileId => _database.profileId;
  Listenable get changes => _changes;

  List<PodcastFeed> get feeds {
    final stored = _database.getSettings(podcastLibrarySettingName)?.value;
    if (_changes.stored == stored) return _changes.feeds;
    _changes.stored = stored;
    _changes.feeds = const [];
    if (stored == null || stored.length > podcastLibraryMaximumBytes) {
      return _changes.feeds;
    }
    try {
      final data = jsonDecode(stored);
      if (data is! Map || data['version'] != 1 || data['feeds'] is! List) {
        return _changes.feeds;
      }
      final unique = <String, PodcastFeed>{};
      for (final row
          in (data['feeds'] as List).take(podcastLibraryMaximumFeeds)) {
        final feed = PodcastFeed.tryParse(row);
        if (feed != null) unique.putIfAbsent(feed.id, () => feed);
      }
      _changes.feeds = List.unmodifiable(unique.values);
    } catch (_) {
      // Damaged metadata never schedules a publisher request or hides the UI.
    }
    return _changes.feeds;
  }

  Future<PodcastFeed> subscribe(String link,
      {bool Function()? isCurrent}) async {
    _requireCurrent(isCurrent);
    final url = PodcastUrlPolicy.parse(link).toString();
    final existing = feeds.where((feed) => feed.feedUrl == url).firstOrNull;
    if (existing != null) return existing;
    return _fetch(url, refreshId: null, isCurrent: isCurrent);
  }

  Future<PodcastFeed> refresh(String id, {bool Function()? isCurrent}) {
    final feed = feeds.where((feed) => feed.id == id).firstOrNull;
    if (feed == null) throw StateError('The podcast subscription was removed.');
    return _fetch(feed.feedUrl, refreshId: id, isCurrent: isCurrent);
  }

  Future<PodcastFeed> _fetch(String url,
      {required String? refreshId, bool Function()? isCurrent}) async {
    _requireCurrent(isCurrent);
    final operation = _changes.operations
        .update(url, (value) => value + 1, ifAbsent: () => 1);
    final feed = await _feedService.fetch(url);
    await _write((items) {
      _requireCurrent(isCurrent);
      if (_changes.operations[url] != operation ||
          (refreshId != null && !items.any((item) => item.id == refreshId))) {
        throw StateError('The podcast operation was cancelled.');
      }
      final index = items.indexWhere((item) => item.id == feed.id);
      if (index < 0) {
        items.add(feed);
      } else {
        items[index] = feed;
      }
    });
    return feed;
  }

  Future<void> remove(String id) {
    final feed = feeds.where((feed) => feed.id == id).firstOrNull;
    if (feed != null) {
      _changes.operations
          .update(feed.feedUrl, (value) => value + 1, ifAbsent: () => 1);
    }
    return _write((items) => items.removeWhere((item) => item.id == id));
  }

  static void _requireCurrent(bool Function()? isCurrent) {
    if (isCurrent != null && !isCurrent()) {
      throw StateError(
          'The active profile changed. Try again in the intended profile.');
    }
  }

  Future<void> _write(void Function(List<PodcastFeed>) change) =>
      _changes.writes = _changes.writes.catchError((_) {}).then((_) async {
        final items = List<PodcastFeed>.of(feeds);
        change(items);
        final value = jsonEncode({
          'version': 1,
          'feeds': items.map((feed) => feed.toJson()).toList(),
        });
        if (items.length > podcastLibraryMaximumFeeds ||
            utf8.encode(value).length > podcastLibraryMaximumBytes) {
          throw StateError(
              'The podcast library is full. Remove a subscription first.');
        }
        await _database
            .saveSetting(SettingsValue(podcastLibrarySettingName, value));
        _changes.changed();
      });
}
