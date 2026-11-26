import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/comments/states/comments.dart';
import 'package:clipious/comments/states/comments_container.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/comments/models/video_comments.dart';

import 'comments.dart';
import 'timed_comments.dart';

class CommentsContainer extends StatelessWidget {
  final Video video;
  final VideoComments? topPage;
  final bool watchStyle;

  const CommentsContainer({
    super.key,
    required this.video,
    this.topPage,
    this.watchStyle = false,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      key: ValueKey(video.videoId),
      create: (context) =>
          CommentsContainerCubit(const CommentsContainerState()),
      child: BlocBuilder<CommentsContainerCubit, CommentsContainerState>(
        builder: (context, state) {
          final locals = AppLocalizations.of(context)!;
          final cubit = context.read<CommentsContainerCubit>();
          final theme = Theme.of(context);
          if (watchStyle) {
            return BlocProvider(
              key: ValueKey(state.source),
              create: (_) => CommentsCubit.forVideo(
                video,
                source: state.source,
                sortBy: 'top',
                initialPage: topPage?.videoId == null ||
                        topPage?.videoId == video.videoId
                    ? topPage
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(locals.comments, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final (sort, label) in [
                          ('top', locals.topSorting),
                          ('new', locals.newSorting),
                          ('timed', locals.timedCommentsSorting),
                        ])
                          ChoiceChip(
                            label: Text(label),
                            selected: state.sortBy == sort,
                            onSelected: (_) => cubit.changeSorting(sort),
                          ),
                      ],
                    ),
                    Expanded(
                      child: state.sortBy == 'timed'
                          ? const TimedCommentsView()
                          : SingleChildScrollView(
                              key: ValueKey(state.sortBy),
                              child: state.sortBy == 'top'
                                  ? const CommentsList()
                                  : CommentsView(
                                      video: video,
                                      source: state.source,
                                      sortBy: state.sortBy,
                                    ),
                            ),
                    ),
                  ],
                ),
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      locals.comments,
                      style: theme.textTheme.titleMedium
                          ?.copyWith(color: theme.colorScheme.secondary),
                    ),
                  ),
                  DropdownButton<String>(
                    value: state.sortBy,
                    onChanged: cubit.changeSorting,
                    items: [
                      DropdownMenuItem(
                        value: 'top',
                        child: Text(locals.topSorting),
                      ),
                      DropdownMenuItem(
                        value: 'new',
                        child: Text(locals.newSorting),
                      ),
                    ],
                  )
                ],
              ),
              CommentsView(
                key: ValueKey('comments-${state.sortBy}-${state.source}'),
                video: video,
                source: state.source,
                sortBy: state.sortBy,
                initialPage: state.sortBy == 'top' ? topPage : null,
              ),
            ],
          );
        },
      ),
    );
  }
}
