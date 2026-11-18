import 'package:clipious/utils/motion.dart';
import 'package:clipious/globals.dart';
import 'package:auto_route/auto_route.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/video_filter.dart';
import 'package:clipious/settings/states/video_filter_channel.dart';
import 'package:clipious/settings/views/components/video_filter_item.dart';
import 'package:clipious/utils/views/components/thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';

import '../../../utils/models/image_object.dart';
import '../../models/db/video_filter.dart';

class VideoFilterChannel extends StatelessWidget {
  final List<VideoFilter> filters;

  const VideoFilterChannel({super.key, required this.filters});

  void editFilter(BuildContext context, {required VideoFilter filter}) {
    var cubit = context.read<VideoFilterCubit>();

    AutoRouter.of(context)
        .push(
            VideoFilterSetupRoute(channelId: filter.channelId, filter: filter))
        .then((value) => cubit.refreshFilters());
  }

  Future<void> confirmDelete(BuildContext context, VideoFilter filter) async {
    final cubit = context.read<VideoFilterChannelCubit>();
    final filterCubit = context.read<VideoFilterCubit>();
    final profile = db.profileId;
    final locals = AppLocalizations.of(context)!;
    final remove = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (dialogContext) => AlertDialog(
        title: Text(locals.delete),
        content: Text(filter.localizedLabel(locals, context)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(locals.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(locals.delete),
          ),
        ],
      ),
    );
    if (remove == true &&
        context.mounted &&
        !cubit.isClosed &&
        !filterCubit.isClosed &&
        db.profileId == profile) {
      await cubit.deleteFilter(filter);
      if (!filterCubit.isClosed) filterCubit.refreshFilters();
    }
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colors = Theme.of(context).colorScheme;

    return BlocProvider(
      create: (context) =>
          VideoFilterChannelCubit(VideoFilterChannelState(filters: filters)),
      child: BlocBuilder<VideoFilterChannelCubit, VideoFilterChannelState>(
        builder: (context, state) {
          var cubit = context.read<VideoFilterChannelCubit>();
          TextStyle titleStyle = TextStyle(color: colors.primary);

          return Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Visibility(
                        visible: !cubit.hasChannel(),
                        child: Text(
                          locals.videoFilterAllChannels,
                          style: titleStyle,
                        ),
                      ),
                      Visibility(
                          visible: state.loading,
                          child: const SizedBox(
                              height: 20,
                              width: 20,
                              child: MotionLoadingIndicator(
                                  child: CircularProgressIndicator(
                                strokeWidth: 1,
                              )))),
                      Visibility(
                          visible: cubit.hasChannel() && !state.loading,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8.0),
                            child: Thumbnail(
                              thumbnails:
                                  ImageObject.getThumbnailUrlsByPreferredOrder(
                                      state.channel?.authorThumbnails),
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20)),
                            ),
                          )),
                      Expanded(
                          child: Visibility(
                              visible: cubit.hasChannel(),
                              child: Text(
                                state.channel?.author ?? '',
                                style: titleStyle,
                              ))),
                    ],
                  ),
                ),
                ...state.filters.map((e) => InkWell(
                    key: ValueKey('filter-${e.uuid}'),
                    onTap: () => editFilter(context, filter: e),
                    onLongPress: () => confirmDelete(context, e),
                    child: VideoFilterItem(filter: e)))
              ],
            ),
          );
        },
      ),
    );
  }
}
