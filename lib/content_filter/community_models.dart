import 'package:unorm_dart/unorm_dart.dart' as unicode;

enum CommunityList { aislist, aimusic }

enum CommunityAction { off, label, hide }

enum CommunityRule {
  youtubeBlock(
      CommunityList.aislist, 'community-youtube-block', CommunityAction.hide),
  youtubeWarn(
      CommunityList.aislist, 'community-youtube-warn', CommunityAction.label),
  music(CommunityList.aimusic, 'community-music', CommunityAction.off);

  const CommunityRule(this.source, this.setting, this.setupDefault);

  final CommunityList source;
  final String setting;
  final CommunityAction setupDefault;
}

class CommunityMatch {
  const CommunityMatch({
    required this.source,
    required this.action,
    required this.warning,
    required this.identity,
  });

  final CommunityList source;
  final CommunityAction action;
  final bool warning;
  final String identity;
}

class CommunitySnapshot {
  CommunitySnapshot({
    required this.version,
    required this.generatedAt,
    required Set<String> blockIds,
    required Set<String> blockHandles,
    required Set<String> warnIds,
    required Set<String> warnHandles,
    this.checkedAt,
  })  : blockIds = Set.unmodifiable(blockIds),
        blockHandles = Set.unmodifiable(blockHandles),
        warnIds = Set.unmodifiable(warnIds),
        warnHandles = Set.unmodifiable(warnHandles);

  final int version;
  final DateTime generatedAt;
  final DateTime? checkedAt;
  final Set<String> blockIds;
  final Set<String> blockHandles;
  final Set<String> warnIds;
  final Set<String> warnHandles;
}

abstract interface class CommunityListStore {
  Future<CommunitySnapshot?> load(CommunityList list);

  Future<CommunitySnapshot> refresh(CommunityList list,
      {required bool Function() isCurrent});
}

final _idPattern = RegExp(r'^UC[a-zA-Z0-9_-]{22}$');
final _channelAuthorUrl = RegExp(
    r'^(?:https://(?:www\.|m\.|music\.)?youtube\.com)?(/channel/UC[a-zA-Z0-9_-]{22})$',
    caseSensitive: false);
final _handleWhitespace = RegExp(
    r'[\u0009-\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]');
final _handleForbidden = RegExp(r'[/@?#\\\x00-\x1F\x7F]');

String? normalizeChannelId(String? input) {
  if (input == null) return null;
  final id = input.startsWith('/channel/') ? input.substring(9) : input;
  return _idPattern.hasMatch(id) && id.length == 24 ? id : null;
}

/// Accept a canonical channel path, with an optional public YouTube origin.
String? channelIdFromAuthorUrl(String? authorUrl) {
  if (authorUrl == null || authorUrl.length > 2048) return null;
  final match = _channelAuthorUrl.firstMatch(authorUrl);
  if (match == null || match.end != authorUrl.length) return null;
  return normalizeChannelId(match[1]);
}

String? normalizeChannelHandle(String? input) {
  if (input == null || input.length > 256) return null;
  final value = input.startsWith('@') ? input.substring(1) : input;
  if (value.isEmpty ||
      value.runes.length > 64 ||
      _handleWhitespace.hasMatch(value) ||
      _handleForbidden.hasMatch(value)) {
    return null;
  }
  return unicode.nfc(value).toLowerCase();
}

String? channelHandleFromAuthorUrl(String? authorUrl) {
  if (authorUrl == null || authorUrl.length > 2048) return null;
  if (authorUrl.startsWith('@')) return normalizeChannelHandle(authorUrl);
  final uri = Uri.tryParse(authorUrl);
  if (uri == null || uri.userInfo.isNotEmpty || uri.hasPort) return null;
  if (uri.hasAuthority || uri.hasScheme) {
    if (uri.scheme != 'https' ||
        !const {
          'www.youtube.com',
          'youtube.com',
          'm.youtube.com',
          'music.youtube.com'
        }.contains(uri.host)) {
      return null;
    }
  } else if (!uri.path.startsWith('/')) {
    return null;
  }
  try {
    final segments = uri.pathSegments;
    if (segments.length != 1 || !segments.single.startsWith('@')) return null;
    return normalizeChannelHandle(segments.single);
  } on FormatException {
    return null;
  }
}
