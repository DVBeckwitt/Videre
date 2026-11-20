import '../../content_filter/community_filter.dart';
import '../../globals.dart' show db;
import '../../utils/video_post_processing.dart' show privateVideoString;
import '../../videos/models/video.dart';

bool musicVideoAvailable(Video video) =>
    video.title != privateVideoString &&
    video.liveNow != true &&
    video.isUpcoming != true &&
    (video.premiereTimestamp ?? 0) <=
        DateTime.now().millisecondsSinceEpoch ~/ 1000;

bool musicVideoAllowed(Video video) =>
    !video.filtered &&
    !video.filterHide &&
    musicVideoAvailable(video) &&
    !db.getAllFilters().any((filter) => filter.filterVideo(video)) &&
    !communityFilters
        .match(
            authorId: video.authorId, authorUrl: video.authorUrl, music: true)
        .any((match) => match.action == CommunityAction.hide);

final _videoLabel = RegExp(r'\b(?:official\s+(?:music\s+)?video|music video)\b',
    caseSensitive: false);
final _videoDescription = RegExp(
    r'^(?:the |watch the )?official (?:music )?video (?:for|by|of)\b',
    caseSensitive: false);
final _audioLabel = RegExp(
    r'\b(?:lyrics?|lyric video|visuali[sz]er|audio only|official audio|full album|fan[- ]?(?:made|video|edit))\b|[\[(]\s*audio\s*[\])]|(?:\s[-–—|]\s*audio)$',
    caseSensitive: false);
final _uploadSuffix = RegExp(
    r'(?:\s*[\[(]\s*(?:official (?:music video|video|audio)|music video|audio|lyrics?(?: video)?|official lyrics?(?: video)?|(?:4k|hd)(?: remaster(?:ed)?)?)\s*[\])]|'
    r'\s+[-–—|]\s*(?:official (?:music video|video|audio)|music video|lyrics?))\s*$',
    caseSensitive: false);
final _artistPrefix = RegExp(r'\s+[-–—]\s+');
final _channelSuffix = RegExp(r'(?:\s+-\s+Topic|VEVO)$', caseSensitive: false);
final _whitespace = RegExp(r'\s+');
final _controls = RegExp(r'[\x00-\x1f\x7f]');

String _artistKey(String? text) => (text ?? '')
    .replaceFirst(_channelSuffix, '')
    .toLowerCase()
    .replaceAll(_whitespace, '')
    .replaceAll('’', "'");

String _recordingTitle(String label, Set<String> artists) {
  var title = label.trim();
  final split = _artistPrefix.firstMatch(title);
  if (split != null &&
      artists.contains(_artistKey(title.substring(0, split.start)))) {
    title = title.substring(split.end);
  }
  while (_uploadSuffix.hasMatch(title)) {
    title = title.replaceFirst(_uploadSuffix, '').trimRight();
  }
  return title.replaceAll(_whitespace, ' ');
}

/// Stock Invidious does not distinguish moving videos from static uploads by
/// stream type. Both commonly advertise video frames for the entire song.
bool isVisualMusicUpload(Video video) {
  return video.genre?.trim().toLowerCase() == 'music' &&
      hasMusicVideoLabel(video);
}

/// Search rows usually omit the genre. Prefer clearly labeled candidates,
/// then verify their full metadata before admitting a video.
bool hasMusicVideoLabel(Video video) {
  final title = video.title ?? '';
  final author = (video.author ?? '').trim();
  return video.musicMetadata?.isArtTrack != true &&
      !video.isStockArtTrack &&
      !author.toLowerCase().endsWith(' - topic') &&
      !_audioLabel.hasMatch(title) &&
      (_videoLabel.hasMatch(title) ||
          _videoDescription.hasMatch((video.description ?? '').trimLeft()) ||
          author.toUpperCase().endsWith('VEVO'));
}

/// A separate video must match this recording closely enough to accompany
/// the current, independently playing audio. Preserve mix/version qualifiers.
class MusicVideoRecording {
  final String title;
  final String artist;
  final Set<String> _artistNames;
  final Set<String> _channelIds;
  final int _seconds;

  MusicVideoRecording._(this.title, this.artist, this._artistNames,
      this._channelIds, this._seconds);

  static MusicVideoRecording? fromSong(Video song) {
    final music = song.musicMetadata;
    final seconds = song.lengthSeconds;
    if (music == null || seconds == null || seconds <= 0) return null;
    final artist = music.artist.trim().replaceFirst(_channelSuffix, '').trim();
    if (artist.isEmpty ||
        artist.length > 240 ||
        music.title.length > 320 ||
        _controls.hasMatch(artist) ||
        _controls.hasMatch(music.title)) {
      return null;
    }
    final names = {
      _artistKey(artist),
      for (final credit in music.artistCredits) _artistKey(credit.name),
    }..remove('');
    final title = _recordingTitle(music.title, names);
    if (title.isEmpty || title == song.videoId) return null;
    return MusicVideoRecording._(
        title,
        artist,
        names,
        {
          if (song.authorId?.isNotEmpty == true) song.authorId!,
          for (final credit in music.artistCredits)
            if (credit.id?.isNotEmpty == true) credit.id!,
        },
        seconds);
  }

  bool matches(Video candidate, {required bool fullMetadata}) {
    final label = candidate.title?.trim() ?? '';
    final seconds = candidate.lengthSeconds;
    if (label.isEmpty ||
        (candidate.author ?? '').trim().toLowerCase().endsWith(' - topic') ||
        _audioLabel.hasMatch(label) ||
        (seconds == null ? fullMetadata : (seconds - _seconds).abs() > 2)) {
      return false;
    }
    final uploader = _artistKey(candidate.author);
    if (!_artistNames.contains(uploader) &&
        !_channelIds.contains(candidate.authorId)) {
      return false;
    }
    String key(String text) => text.toLowerCase().replaceAll('’', "'");
    return key(_recordingTitle(label, {..._artistNames, uploader})) ==
        key(title);
  }
}
