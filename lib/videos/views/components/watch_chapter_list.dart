import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../models/video_chapter.dart';

class WatchChapterList extends StatelessWidget {
  final PlayerCubit player;
  final List<VideoChapter> chapters;
  final bool Function() isCurrent;
  final bool showHeading;

  const WatchChapterList({
    super.key,
    required this.player,
    required this.chapters,
    required this.isCurrent,
    required this.showHeading,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final locals = AppLocalizations.of(context)!;
    return BlocSelector<PlayerCubit, PlayerState, ({bool enabled, int active})>(
      bloc: player,
      selector: (state) {
        final enabled = isCurrent();
        return (
          enabled: enabled,
          active: enabled
              ? chapters
                  .lastIndexWhere((chapter) => chapter.start <= state.position)
              : -1,
        );
      },
      builder: (context, selection) {
        final current = selection.active < 0
            ? null
            : Text(
                key: const ValueKey('watch-current-chapter'),
                chapters[selection.active].title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              );
        return Column(
          children: [
            if (showHeading || current != null)
              ListTile(
                title: showHeading ? Text(locals.videoChapters) : current,
                subtitle: showHeading ? current : null,
                trailing: showHeading
                    ? IconButton(
                        tooltip:
                            MaterialLocalizations.of(context).closeButtonLabel,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.of(context).pop(),
                      )
                    : null,
              ),
            Expanded(
              child: ListView.builder(
                key: const ValueKey('watch-chapter-list'),
                itemCount: chapters.length,
                itemBuilder: (context, index) {
                  final chapter = chapters[index];
                  return ListTile(
                    title: Text(chapter.title),
                    trailing: Text(prettyDurationCustom(chapter.start)),
                    selected: index == selection.active,
                    selectedColor: colors.onSecondaryContainer,
                    selectedTileColor: colors.secondaryContainer,
                    enabled: selection.enabled,
                    onTap: selection.enabled
                        ? () {
                            if (isCurrent()) player.seek(chapter.start);
                          }
                        : null,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
