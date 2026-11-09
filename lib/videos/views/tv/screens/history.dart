import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/states/app.dart';
import '../../../../globals.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../music/views/screens/music.dart';
import '../../../../router.dart';
import '../../../../utils/models/paginated_list.dart';
import '../../../../utils/motion.dart';
import '../../../../utils/states/item_list.dart';
import '../../../../utils/views/tv/components/tv_button.dart';
import '../../../../utils/views/tv/components/tv_overscan.dart';
import '../../../models/video.dart';
import '../../../states/video_in_list.dart';
import '../components/video_item.dart';

class TvHistoryScreen extends StatefulWidget {
  final Future<void> Function(BuildContext context, Video video)? onOpenVideo;

  const TvHistoryScreen({super.key, this.onOpenVideo});

  @override
  State<TvHistoryScreen> createState() => _TvHistoryScreenState();
}

class _TvHistoryScreenState extends State<TvHistoryScreen> {
  bool _local = true;

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select((AppCubit app) => app.isLoggedIn);
    final server = context.select((AppCubit app) => app.state.server);
    final showLocal = _local || !loggedIn;
    final locals = AppLocalizations.of(context)!;
    return BlocProvider(
      // Discard in-flight account requests when changing source or account.
      key: ValueKey((showLocal, ObjectKey(server))),
      create: (_) => ItemListCubit<String>(ItemListState(
        itemList: _HistoryPages(
          getItemsFunc:
              showLocal ? service.getLocalHistoryPage : service.getUserHistory,
        ),
      )),
      child: Scaffold(
        body: TvOverscan(
          child: BlocBuilder<ItemListCubit<String>, ItemListState<String>>(
            builder: (context, state) {
              final list = context.read<ItemListCubit<String>>();
              final hasError = state.error != ItemListErrors.none;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(locals.history,
                      style: Theme.of(context).textTheme.titleLarge),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _action(
                          key: const ValueKey('tv-history-local'),
                          label: locals.onDevice,
                          icon: showLocal ? Icons.check : Icons.tv,
                          autofocus: showLocal,
                          onPressed: (_) => setState(() => _local = true),
                        ),
                        if (loggedIn)
                          _action(
                            key: const ValueKey('tv-history-server'),
                            label: locals.onServer,
                            icon:
                                !showLocal ? Icons.check : Icons.cloud_outlined,
                            autofocus: !showLocal,
                            onPressed: (_) => setState(() => _local = false),
                          ),
                        _action(
                          key: const ValueKey('tv-history-refresh'),
                          label: locals.refresh,
                          icon: Icons.refresh,
                          onPressed: (_) {
                            if (!state.loading) {
                              unawaited(service.syncHistory());
                              list.refreshItems();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  if (state.loading)
                    const SizedBox(
                      height: 3,
                      child: MotionLoadingIndicator(
                          child: LinearProgressIndicator()),
                    )
                  else
                    const SizedBox(height: 3),
                  Expanded(
                    child: state.items.isEmpty
                        ? Center(
                            child: Text(!state.loading && !hasError
                                ? locals.noHistory
                                : ''),
                          )
                        : GridView.builder(
                            controller: list.scrollController,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              childAspectRatio: 16 / 13,
                            ),
                            itemCount: state.items.length,
                            findChildIndexCallback: (key) {
                              final index = state.items
                                  .indexOf((key as ValueKey<String>).value);
                              return index < 0 ? null : index;
                            },
                            itemBuilder: (context, index) => _HistoryVideo(
                              key: ValueKey(state.items[index]),
                              videoId: state.items[index],
                              onOpen: (cardContext, video) async {
                                final oldIndex =
                                    list.state.items.indexOf(video.videoId);
                                final rowHeight = cardContext.size?.height;
                                if (widget.onOpenVideo != null) {
                                  await widget.onOpenVideo!(cardContext, video);
                                } else if (video.musicMetadata != null) {
                                  try {
                                    await MusicScreen.playTracks(
                                        cardContext, [video]);
                                  } catch (_) {
                                    if (cardContext.mounted) {
                                      ScaffoldMessenger.of(cardContext)
                                          .showSnackBar(SnackBar(
                                              content: Text(
                                                  locals.musicPlaybackError)));
                                    }
                                  }
                                } else {
                                  await AutoRouter.of(cardContext).push(
                                      TvVideoRoute(videoId: video.videoId));
                                }
                                if (cardContext.mounted) {
                                  cardContext
                                      .read<VideoInListCubit>()
                                      .updateProgress();
                                }
                                if (list.isClosed) return;
                                await list.refreshItems();
                                if (list.isClosed) return;
                                final newIndex =
                                    list.state.items.indexOf(video.videoId);
                                if (newIndex >= 0 &&
                                    newIndex != oldIndex &&
                                    rowHeight != null &&
                                    list.scrollController.hasClients) {
                                  // Playback moves local history to the front.
                                  // Move the viewport before the refreshed grid
                                  // lays out, keeping its focused child alive.
                                  list.scrollController.jumpTo(
                                      ((newIndex ~/ 3) * rowHeight).clamp(
                                          0,
                                          list.scrollController.position
                                              .maxScrollExtent));
                                }
                              },
                            ),
                          ),
                  ),
                  if (hasError)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(switch (state.error) {
                        ItemListErrors.nerdVpnApprovalPending =>
                          locals.nerdVpnAccessPendingShort,
                        ItemListErrors.invalidScope =>
                          locals.itemListErrorInvalidScope,
                        _ => locals.itemlistErrorGeneric,
                      }),
                    ),
                  if (hasError || list.state.itemList.getHasMore())
                    _action(
                      key: const ValueKey('tv-history-more'),
                      label: hasError ? locals.retry : locals.loadMore,
                      icon: hasError ? Icons.refresh : Icons.expand_more,
                      onPressed: (_) {
                        if (!state.loading) {
                          hasError ? list.retryItems() : list.getMoreItems();
                        }
                      },
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HistoryPages extends PageBasedPaginatedList<String> {
  _HistoryPages({required super.getItemsFunc}) : super(maxResults: 20);

  // New watches can shift page boundaries while another page is loading.
  // Keep raw page lengths for pagination, but give each visible video one key.
  @override
  List<String> visibleItems(List<String> items) => items.toSet().toList();
}

Widget _action({
  required Key key,
  required String label,
  required IconData icon,
  required void Function(BuildContext) onPressed,
  bool autofocus = false,
}) =>
    IntrinsicWidth(
        child: TvButton(
      key: key,
      autofocus: autofocus,
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon),
          const SizedBox(width: 8),
          Text(label),
        ]),
      ),
    ));

class _HistoryVideo extends StatefulWidget {
  final String videoId;
  final Future<void> Function(BuildContext context, Video video) onOpen;

  const _HistoryVideo({super.key, required this.videoId, required this.onOpen});

  @override
  State<_HistoryVideo> createState() => _HistoryVideoState();
}

class _HistoryVideoState extends State<_HistoryVideo> {
  late Future<Video> _video = _loadVideo();

  Future<Video> _loadVideo() async {
    final cached = db.getHistoryVideoByVideoId(widget.videoId);
    // Viewing server history must not mark its entries watched on this device.
    return cached?.toVideo() ?? await service.getVideo(widget.videoId);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return FutureBuilder<Video>(
      future: _video,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: _action(
              key: ValueKey('tv-history-video-retry-${widget.videoId}'),
              label: '${locals.retry}\n${widget.videoId}',
              icon: Icons.refresh,
              onPressed: (_) => setState(() {
                _video = _loadVideo();
              }),
            ),
          );
        }
        final video = snapshot.data;
        if (video == null) {
          return const Center(
            child: MotionLoadingIndicator(child: CircularProgressIndicator()),
          );
        }
        return TvVideoItem(
          key: ValueKey(widget.videoId),
          video: video,
          autoFocus: false,
          onSelect: widget.onOpen,
          onFocusChange: (focused) {
            if (focused) {
              Scrollable.ensureVisible(context,
                  duration: AppMotion.duration(context),
                  alignmentPolicy:
                      ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
            }
          },
        );
      },
    );
  }
}
