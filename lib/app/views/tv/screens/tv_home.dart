import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/tv_home.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/home/models/content_mode.dart';
import 'package:clipious/home/views/components/flow_video_home.dart';
import 'package:clipious/music/views/screens/music_discovery.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:clipious/music/views/screens/music_library.dart';
import 'package:clipious/podcasts/views/podcast_player_controls.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/utils/models/paginated_list.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:clipious/videos/views/components/subscriptions.dart';
import 'package:clipious/videos/views/components/trending.dart';

import '../../../../home/models/db/home_layout.dart';
import '../../../../player/views/tv/screens/tv_player_view.dart';
import '../../../../router.dart';
import '../../../../utils/views/components/app_icon.dart';
import '../../../../videos/views/components/popular.dart';
import '../../../../videos/views/tv/screens/history.dart';
import '../../../states/app.dart';

const overlayBackgroundOpacity = 0.8;
const double overlayBlur = 25.0;

@RoutePage()
class TvHomeScreen extends StatelessWidget {
  const TvHomeScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      BlocSelector<AppCubit, AppState, (String, int)>(
        selector: (state) => (state.profileId, state.sessionRevision),
        builder: (context, session) => _TvHomeContent(key: ValueKey(session)),
      );
}

class _TvHomeContent extends StatefulWidget {
  const _TvHomeContent({super.key});

  @override
  State<_TvHomeContent> createState() => _TvHomeContentState();
}

class _TvHomeContentState extends State<_TvHomeContent> {
  final popularTitle = GlobalKey(debugLabel: 'popular title');
  final subscriptionTitle = GlobalKey(debugLabel: 'subscription title');
  final trendingTitle = GlobalKey(debugLabel: 'trending title');
  final _visitedMusicPages = <int>{};
  final _musicMenuKeys = List.generate(3, (_) => GlobalKey());
  final _musicDestination = GlobalKey();
  final _pageStorage = PageStorageBucket();
  int _musicPage = 0;
  bool _videosVisited = false;
  bool _switchingMode = false;

  void _focusMenuItem(GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = key.currentContext;
      if (!mounted || target == null) return;
      Focus.of(target).requestFocus();
      Scrollable.ensureVisible(target);
    });
  }

  void _openMusicPage(int index) {
    setState(() {
      _musicPage = index;
      _visitedMusicPages.add(index);
    });
    // Home shortcuts also leave focus on a visible control in the new page.
    _focusMenuItem(_musicMenuKeys[index]);
  }

  Future<void> _openMode(HomeContentMode mode) async {
    if (_switchingMode) return;
    final settings = context.read<SettingsCubit>();
    _switchingMode = true;
    try {
      await settings.setHomeContentMode(mode);
      if (mounted && settings.state.homeContentMode == mode) {
        _focusMenuItem(mode == HomeContentMode.music
            ? _musicMenuKeys[_musicPage]
            : _musicDestination);
      }
    } catch (_) {
      if (mounted) {
        final locals = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.phoneNavigationSaveError)));
      }
    } finally {
      _switchingMode = false;
    }
  }

  Widget _modeDestination(
      TvHomeCubit home, bool expanded, HomeContentMode mode, String label,
      {bool autofocus = false}) {
    final opensMusic = mode == HomeContentMode.music;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: TvButton(
          key: ValueKey('tv-home-${mode.name}'),
          autofocus: autofocus,
          onFocusChanged: home.menuItemFocusChanged,
          onPressed: (_) => _openMode(mode),
          unfocusedColor: Colors.transparent,
          child: Padding(
            key: opensMusic ? _musicDestination : null,
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child:
                    Icon(opensMusic ? Icons.music_note : Icons.ondemand_video),
              ),
              if (expanded) Expanded(child: MenuItemText(label)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _videoDestination(
      TvHomeCubit home, bool expanded, HomeDataSource source, String label,
      {required bool autofocus}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TvButton(
        key: ValueKey('tv-home-page-${source.name}'),
        autofocus: autofocus,
        onFocusChanged: home.menuItemFocusChanged,
        onPressed: (context) => switch (source) {
          HomeDataSource.search => openSearch(context),
          HomeDataSource.subscription => openSubscriptions(context),
          HomeDataSource.history => openHistory(context),
          HomeDataSource.playlist => openPlaylists(context),
          HomeDataSource.trending => openTrending(context),
          HomeDataSource.popular => openPopular(context),
          _ => null,
        },
        unfocusedColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(source.getIcon()),
            ),
            if (expanded) Expanded(child: MenuItemText(label)),
          ]),
        ),
      ),
    );
  }

  void openSettings(BuildContext context) {
    AutoRouter.of(context).push(const TVSettingsRoute());
  }

  void openPopular(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    AutoRouter.of(context).push(TvGridRoute(
        paginatedVideoList: SingleEndpointList(service.getPopular),
        title: locals.popular));
  }

  void openTrending(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    AutoRouter.of(context).push(TvGridRoute(
        paginatedVideoList: SingleEndpointList(service.getTrending),
        title: locals.trending));
  }

  void openSubscriptions(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    AutoRouter.of(context).push(TvGridRoute(
        paginatedVideoList: SubscriptionVideoList(),
        title: locals.subscriptions));
  }

  void openSearch(BuildContext context) {
    AutoRouter.of(context).push(TvSearchRoute());
  }

  void openPlaylists(BuildContext context) {
    AutoRouter.of(context).push(TvPlaylistGridRoute(
        playlistList: SingleEndpointList(service.getUserPlaylists),
        includeSavedPlaylists: true));
  }

  void openForYou(BuildContext context) {
    final title = AppLocalizations.of(context)!.flowForYou;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: Scaffold(
          appBar: AppBar(title: Text(title)),
          body: const Padding(
            padding: EdgeInsets.symmetric(
                horizontal: TvOverscan.horizontal,
                vertical: TvOverscan.vertical),
            child: FlowVideoHome(television: true),
          ),
        ),
      ),
    ));
  }

  void openHistory(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const TvHistoryScreen()));
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colors = Theme.of(context).colorScheme;
    TextTheme textTheme = Theme.of(context).textTheme;
    var locals = AppLocalizations.of(context)!;
    return PageStorage(
      bucket: _pageStorage,
      child: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: BlocProvider(
          create: (BuildContext context) => TvHomeCubit(false),
          child: Scaffold(
            bottomNavigationBar: const PodcastPlaybackBar(
                padding: EdgeInsets.symmetric(
                    horizontal: TvOverscan.horizontal,
                    vertical: TvOverscan.vertical)),
            body: BlocBuilder<TvHomeCubit, bool>(builder: (context, homeState) {
              var homeCubit = context.read<TvHomeCubit>();
              final mode = context
                  .select((SettingsCubit value) => value.state.homeContentMode);
              final music = mode == HomeContentMode.music;
              if (music) _visitedMusicPages.add(_musicPage);
              if (!music) _videosVisited = true;
              var appLayout = context
                  .select((SettingsCubit value) => value.state.appLayout);
              var isLoggedIn =
                  context.select((AppCubit value) => value.isLoggedIn);
              var allowedPages = appLayout
                  .where((element) => element.isPermitted(context, isLoggedIn))
                  .toList();
              return BlocBuilder<AppCubit, AppState>(
                  buildWhen: (previous, current) {
                return previous.server != current.server;
              }, builder: (context, state) {
                return DefaultTextStyle(
                  style: textTheme.bodyLarge!,
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(0),
                          child: AnimatedContainer(
                            width: homeState ? 250 : 118,
                            duration: AppMotion.duration(
                                context, animationDuration ~/ 2),
                            curve: Curves.easeInOutQuad,
                            decoration: BoxDecoration(
                                color: homeState
                                    ? colors.secondaryContainer
                                        .withValues(alpha: 0.5)
                                    : Colors.transparent),
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: homeState ? 250 : 118,
                                maxWidth: homeState ? 250 : 118,
                                child: Padding(
                                    padding: EdgeInsets.only(
                                        top: TvOverscan.vertical,
                                        left: TvOverscan.horizontal,
                                        bottom: TvOverscan.vertical,
                                        right: homeState
                                            ? TvOverscan.horizontal
                                            : 8),
                                    // Keep the small menu's focus nodes mounted
                                    // as Videos/Music changes its length.
                                    child: SingleChildScrollView(
                                        child: Column(children: [
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 30.0),
                                        child: SizedBox(
                                            height: 50,
                                            child: Row(
                                              children: [
                                                const AppIcon(
                                                  width: 50,
                                                  height: 50,
                                                ),
                                                if (homeState)
                                                  Expanded(
                                                      child: Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(
                                                                  left: 16.0),
                                                          child: MenuItemText(
                                                            'Videre',
                                                            style: textTheme
                                                                .titleLarge!
                                                                .copyWith(
                                                                    color: colors
                                                                        .primary),
                                                          )))
                                              ],
                                            )),
                                      ),
                                      if (music) ...[
                                        _modeDestination(
                                            homeCubit,
                                            homeState,
                                            HomeContentMode.videos,
                                            locals.videos),
                                        ...[
                                          (locals.home, Icons.home_outlined),
                                          (locals.search, Icons.search),
                                          (
                                            locals.musicLibrary,
                                            Icons.library_music
                                          ),
                                        ].indexed.map((entry) => Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 8),
                                              child: Semantics(
                                                button: true,
                                                selected:
                                                    _musicPage == entry.$1,
                                                label: entry.$2.$1,
                                                child: TvButton(
                                                  key: ValueKey(
                                                      'tv-music-page-${entry.$1}'),
                                                  autofocus: entry.$1 == 0,
                                                  onFocusChanged: homeCubit
                                                      .menuItemFocusChanged,
                                                  onPressed: (_) =>
                                                      _openMusicPage(entry.$1),
                                                  unfocusedColor: _musicPage ==
                                                          entry.$1
                                                      ? colors
                                                          .secondaryContainer
                                                      : Colors.transparent,
                                                  child: Padding(
                                                    key: _musicMenuKeys[
                                                        entry.$1],
                                                    padding:
                                                        const EdgeInsets.all(8),
                                                    child: Row(children: [
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .only(right: 8),
                                                        child:
                                                            Icon(entry.$2.$2),
                                                      ),
                                                      if (homeState)
                                                        Expanded(
                                                            child: MenuItemText(
                                                                entry.$2.$1)),
                                                    ]),
                                                  ),
                                                ),
                                              ),
                                            ))
                                      ] else ...[
                                        for (final page in allowedPages) ...[
                                          if (page == HomeDataSource.search)
                                            _modeDestination(
                                                homeCubit,
                                                homeState,
                                                HomeContentMode.music,
                                                locals.music),
                                          _videoDestination(
                                              homeCubit,
                                              homeState,
                                              page,
                                              page.getLabel(locals),
                                              autofocus:
                                                  page == allowedPages.first),
                                        ],
                                        if (!allowedPages
                                            .contains(HomeDataSource.search))
                                          _modeDestination(
                                              homeCubit,
                                              homeState,
                                              HomeContentMode.music,
                                              locals.music,
                                              autofocus: allowedPages.isEmpty),
                                      ],
                                      if (!music)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 8),
                                          child: TvButton(
                                            key: const ValueKey(
                                                'tv-home-for-you'),
                                            onFocusChanged:
                                                homeCubit.menuItemFocusChanged,
                                            onPressed: openForYou,
                                            unfocusedColor: Colors.transparent,
                                            child: Padding(
                                              padding: const EdgeInsets.all(8),
                                              child: Row(children: [
                                                const Padding(
                                                  padding:
                                                      EdgeInsets.only(right: 8),
                                                  child: Icon(Icons
                                                      .auto_awesome_outlined),
                                                ),
                                                if (homeState)
                                                  Expanded(
                                                      child: MenuItemText(
                                                          locals.flowForYou)),
                                              ]),
                                            ),
                                          ),
                                        ),
                                      TvButton(
                                        key: const ValueKey('tv-home-profiles'),
                                        onFocusChanged:
                                            homeCubit.menuItemFocusChanged,
                                        onPressed: (context) =>
                                            showProfilePicker(context),
                                        unfocusedColor: Colors.transparent,
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Row(children: [
                                            const Padding(
                                              padding:
                                                  EdgeInsets.only(right: 8),
                                              child: Icon(Icons
                                                  .account_circle_outlined),
                                            ),
                                            if (homeState)
                                              Expanded(
                                                  child: MenuItemText(
                                                      locals.profiles)),
                                          ]),
                                        ),
                                      ),
                                      TvButton(
                                        key: const ValueKey('tv-home-remote'),
                                        onFocusChanged:
                                            homeCubit.menuItemFocusChanged,
                                        onPressed: (context) =>
                                            Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                    builder: (_) =>
                                                        const TvPlayerScreen(
                                                            videos: [],
                                                            receiveRemote:
                                                                true))),
                                        unfocusedColor: Colors.transparent,
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Row(children: [
                                            const Padding(
                                                padding:
                                                    EdgeInsets.only(right: 8),
                                                child: Icon(Icons.phonelink)),
                                            if (homeState)
                                              Expanded(
                                                  child: MenuItemText(
                                                      locals.remoteReceive)),
                                          ]),
                                        ),
                                      ),
                                      TvButton(
                                        key: const ValueKey('tv-home-settings'),
                                        onFocusChanged:
                                            homeCubit.menuItemFocusChanged,
                                        onPressed: (context) =>
                                            openSettings(context),
                                        unfocusedColor: colors
                                            .secondaryContainer
                                            .withValues(alpha: 0.0),
                                        child: Padding(
                                          padding: const EdgeInsets.all(8),
                                          child: Row(
                                            children: [
                                              const Padding(
                                                padding:
                                                    EdgeInsets.only(right: 8.0),
                                                child: Icon(Icons.settings),
                                              ),
                                              if (homeState)
                                                Expanded(
                                                    child: MenuItemText(
                                                        locals.settings))
                                            ],
                                          ),
                                        ),
                                      )
                                    ]))),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: FocusTraversalOrder(
                            order: const NumericFocusOrder(1),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: TvOverscan.vertical,
                                    left: 8,
                                    right: TvOverscan.horizontal,
                                    bottom: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Align(
                                          alignment: Alignment.centerLeft,
                                          child: SizedBox(
                                            height: 48,
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Text(
                                                music
                                                    ? locals.music
                                                    : locals.videos,
                                                style: textTheme.titleLarge,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (music)
                                        IconButton(
                                          key:
                                              const ValueKey('tv-music-search'),
                                          tooltip: locals.search,
                                          onPressed: () => _openMusicPage(1),
                                          icon: const Icon(Icons.search),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: IndexedStack(
                                    index: music ? 1 : 0,
                                    children: [
                                      ExcludeFocus(
                                        excluding: music,
                                        child: TickerMode(
                                          enabled: !music,
                                          // terrible work around to be able to scroll to all the global keys
                                          child: !_videosVisited
                                              ? const SizedBox.shrink()
                                              : SingleChildScrollView(
                                                  key: const PageStorageKey(
                                                      'tv-videos-home'),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 0,
                                                            bottom: TvOverscan
                                                                .vertical,
                                                            right: TvOverscan
                                                                .horizontal,
                                                            left: 8),
                                                    child: ListView(
                                                      controller: homeCubit
                                                          .scrollController,
                                                      physics:
                                                          const NeverScrollableScrollPhysics(),
                                                      shrinkWrap: true,
                                                      // crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        ...allowedPages
                                                            .where((e) =>
                                                                e == HomeDataSource.subscription ||
                                                                e ==
                                                                    HomeDataSource
                                                                        .trending ||
                                                                e ==
                                                                    HomeDataSource
                                                                        .popular)
                                                            .map((e) {
                                                          GlobalKey? key =
                                                              switch (e) {
                                                            (HomeDataSource
                                                                  .popular) =>
                                                              popularTitle,
                                                            (HomeDataSource
                                                                  .subscription) =>
                                                              subscriptionTitle,
                                                            (HomeDataSource
                                                                  .trending) =>
                                                              trendingTitle,
                                                            (_) => null,
                                                          };

                                                          focusFunction(video,
                                                              index, focus) {
                                                            if (key != null &&
                                                                focus) {
                                                              Scrollable.ensureVisible(
                                                                  key
                                                                      .currentContext!,
                                                                  duration: AppMotion
                                                                      .duration(
                                                                          context),
                                                                  curve: Curves
                                                                      .easeInOutQuad,
                                                                  alignmentPolicy:
                                                                      ScrollPositionAlignmentPolicy
                                                                          .keepVisibleAtStart);
                                                            }
                                                          }

                                                          return Column(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              Padding(
                                                                key: key,
                                                                padding:
                                                                    const EdgeInsets
                                                                        .only(
                                                                        top:
                                                                            16.0),
                                                                child: Text(
                                                                    e.getLabel(
                                                                        locals),
                                                                    style: textTheme
                                                                        .titleLarge),
                                                              ),
                                                              switch (e) {
                                                                (HomeDataSource
                                                                      .popular) =>
                                                                  Popular(
                                                                    onItemFocus:
                                                                        focusFunction,
                                                                  ),
                                                                (HomeDataSource
                                                                      .subscription) =>
                                                                  Subscriptions(
                                                                    onItemFocus:
                                                                        focusFunction,
                                                                  ),
                                                                (HomeDataSource
                                                                      .trending) =>
                                                                  Trending(
                                                                    onItemFocus:
                                                                        focusFunction,
                                                                  ),
                                                                (_) =>
                                                                  const SizedBox
                                                                      .shrink(),
                                                              }
                                                            ],
                                                          );
                                                        })
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                        ),
                                      ),
                                      ExcludeFocus(
                                        excluding: !music,
                                        child: TickerMode(
                                          enabled: music,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                                right: TvOverscan.horizontal,
                                                bottom: TvOverscan.vertical),
                                            child: IndexedStack(
                                              index: _musicPage,
                                              children: [
                                                for (var index = 0;
                                                    index < 3;
                                                    index++)
                                                  ExcludeFocus(
                                                    excluding:
                                                        index != _musicPage,
                                                    child: TickerMode(
                                                      enabled:
                                                          index == _musicPage,
                                                      child:
                                                          _visitedMusicPages
                                                                  .contains(
                                                                      index)
                                                              ? switch (index) {
                                                                  0 => MusicHomePage(
                                                                      onSearch: () =>
                                                                          _openMusicPage(
                                                                              1),
                                                                      onLibrary:
                                                                          () =>
                                                                              _openMusicPage(2)),
                                                                  1 => const MusicScreen(
                                                                      embedded:
                                                                          true),
                                                                  _ =>
                                                                    const MusicLibraryPage(),
                                                                }
                                                              : const SizedBox
                                                                  .shrink(),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              });
            }),
          ),
        ),
      ),
    );
  }
}

class MenuItemText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const MenuItemText(this.text, {super.key, this.style});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    )
        .animate()
        .fadeIn(
            delay: AppMotion.fadeDuration(context, animationDuration ~/ 2),
            duration: AppMotion.fadeDuration(context, animationDuration ~/ 2))
        .slideX(curve: Curves.easeInOutQuad);
  }
}
