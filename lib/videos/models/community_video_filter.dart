import '../../content_filter/community_filter.dart';
import 'video.dart';

List<CommunityMatch> videoCommunityMatches(Video video) => communityFilters
    .match(authorId: video.authorId, authorUrl: video.authorUrl);

bool hideCommunityVideo(Video video) => videoCommunityMatches(video)
    .any((match) => match.action == CommunityAction.hide);
