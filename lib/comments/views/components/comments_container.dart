import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/comments/states/comments_container.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/comments/models/video_comments.dart';

import 'comments.dart';

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
    var locals = AppLocalizations.of(context)!;
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    var textTheme = Theme.of(context).textTheme;

    return BlocProvider(
      create: (context) =>
          CommentsContainerCubit(const CommentsContainerState()),
      child: BlocBuilder<CommentsContainerCubit, CommentsContainerState>(
        builder: (context, state) {
          var cubit = context.read<CommentsContainerCubit>();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (watchStyle) ...[
                Text(locals.comments, style: textTheme.titleLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text(locals.topSorting),
                      selected: state.sortBy == 'top',
                      onSelected: (_) => cubit.changeSorting('top'),
                    ),
                    ChoiceChip(
                      label: Text(locals.newSorting),
                      selected: state.sortBy == 'new',
                      onSelected: (_) => cubit.changeSorting('new'),
                    ),
                  ],
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        locals.comments,
                        style: textTheme.titleMedium
                            ?.copyWith(color: colorScheme.secondary),
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
                  key: ValueKey<String>(
                      'comments-${state.sortBy}-${state.source}'),
                  video: video,
                  source: state.source,
                  sortBy: state.sortBy,
                  initialPage: state.sortBy == 'top' ? topPage : null),
            ],
          );
        },
      ),
    );
  }
}
