import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/channels/models/channel.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/router.dart';
import 'package:clipious/search/models/search_type.dart';
import 'package:clipious/search/states/search.dart';
import 'package:clipious/search/views/screens/search.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/components/paginated_list_view.dart';
import 'package:clipious/videos/views/components/community_browse.dart';

import '../components/search_channel_hero_card.dart';

@RoutePage()
class SearchChannelTab extends StatelessWidget {
  const SearchChannelTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (context) {
      final query = context.select((SearchCubit s) => s.submittedQuery);
      final sortBy = context.select((SearchCubit s) => s.state.filters.sortBy);
      final date = context.select((SearchCubit s) => s.state.filters.date);
      final duration =
          context.select((SearchCubit s) => s.state.filters.duration);

      return PaginatedListView<Channel>(
          key: ValueKey((query, sortBy, date, duration)),
          communityMatch: channelCommunityMatches,
          paginatedList: PageBasedPaginatedList<Channel>(
            getItemsFunc: (page, maxResults) => service
                .search(query,
                    page: page,
                    sortBy: sortBy,
                    type: SearchType.channel,
                    date: date,
                    duration: duration)
                .then((value) => value.channels),
            maxResults: searchPageSize,
          ),
          itemBuilder: (channel) => SearchChannelHeroCard(
                key: ValueKey(channel.authorId),
                channel: channel,
                onOpen: () => context.router
                    .push(ChannelRoute(channelId: channel.authorId)),
              ));
    });
  }
}
