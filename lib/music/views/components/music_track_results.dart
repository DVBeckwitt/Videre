import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/music/models/music_track.dart';

typedef MusicTrackResult = (MusicTrack, List<CommunityMatch>);

/// Keeps loaded catalog results intact so a preference change, exception or
/// temporary reveal can update the view without issuing another catalog request.
({List<MusicTrackResult> visible, int hidden}) musicTrackResults(
    List<MusicTrack> tracks,
    {required bool showHidden}) {
  final visible = <MusicTrackResult>[];
  var hidden = 0;
  for (final track in tracks) {
    final matches = communityFilters.match(
      authorId: track.uploaderChannelId,
      authorUrl: track.uploaderChannelUrl,
      music: true,
    );
    final hide = matches.any((match) => match.action == CommunityAction.hide);
    if (hide) hidden++;
    if (!hide || showHidden) visible.add((track, matches));
  }
  return (visible: visible, hidden: hidden);
}
