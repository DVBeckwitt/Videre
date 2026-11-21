// Channel search opening/closing and result states translated from Flow's
// ChannelContent.kt, ChannelViewModel.kt and ChannelSearchResults.kt at
// 565d1f7a. Submit and pagination use Videre's admitted Invidious route.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../network/network_proxy.dart';
import '../../../player/models/backend_playback.dart';
import '../../../service.dart';
import '../../../videos/models/community_video_filter.dart';
import '../../../videos/models/video.dart';
import '../../../videos/views/components/community_browse.dart';
import '../../../videos/views/components/video_in_list.dart';

/// Keeps the original tab and scroll positions mounted while searching.
class ChannelSearchShell extends StatefulWidget {
  final String channelId;
  final Widget Function(BuildContext, VoidCallback? openSearch) builder;

  const ChannelSearchShell({
    super.key,
    required this.channelId,
    required this.builder,
  });

  @override
  State<ChannelSearchShell> createState() => _ChannelSearchShellState();
}

class _ChannelSearchShellState extends State<ChannelSearchShell> {
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    NetworkProxy.instance.addBeforeApply(_closeForProxy);
  }

  @override
  void dispose() {
    NetworkProxy.instance.removeBeforeApply(_closeForProxy);
    super.dispose();
  }

  Future<void> _closeForProxy() async => _close();

  void _close() {
    if (_searching && mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<AppCubit, AppState>(
      listenWhen: (before, after) =>
          before.profileId != after.profileId ||
          before.sessionRevision != after.sessionRevision ||
          before.server != after.server ||
          after.globalLoading ||
          after.sessionRecoveryRequired,
      listener: (_, __) => _close(),
      child: PopScope(
        canPop: !_searching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: IndexedStack(
          index: _searching ? 1 : 0,
          children: [
            ExcludeFocus(
              excluding: _searching,
              child: TickerMode(
                enabled: !_searching,
                child: widget.builder(
                  context,
                  Service.canSearchChannel(widget.channelId)
                      ? () => setState(() => _searching = true)
                      : null,
                ),
              ),
            ),
            if (_searching)
              _ChannelSearchPane(
                  channelId: widget.channelId,
                  isOpen: () => mounted && _searching,
                  onClose: _close),
          ],
        ),
      ),
    );
  }
}

class _ChannelSearchPane extends StatefulWidget {
  final String channelId;
  final bool Function() isOpen;
  final VoidCallback onClose;

  const _ChannelSearchPane(
      {required this.channelId, required this.isOpen, required this.onClose});

  @override
  State<_ChannelSearchPane> createState() => _ChannelSearchPaneState();
}

class _ChannelSearchPaneState extends State<_ChannelSearchPane> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _results = <String, Video>{};
  final _owner = db;
  final _profileId = db.profileId;
  final _proxy = NetworkProxy.instance.config;
  final _api = service;
  late final AppCubit _app;
  late final AppState _session;

  BackendPlayback? _route;
  String _query = '';
  int _request = 0;
  int _page = 1;
  bool _loading = false;
  bool _error = false;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    // Freeze the route's account before a user can submit the first page.
    _app = context.read<AppCubit>();
    _session = _app.state;
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final query = String.fromCharCodes(value.trim().runes.take(200)).trim();
    if (query.isEmpty) return;
    _focus.unfocus();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _query = query;
      _page = 1;
      _results.clear();
      _loading = false;
      _hasMore = false;
      _request++;
    });
    _loadPage();
  }

  Future<void> _loadPage() async {
    if (_loading || _query.isEmpty) return;
    final request = _request;
    final query = _query;
    final page = _page;
    bool active() => mounted && widget.isOpen() && _request == request;
    bool sameConnection() =>
        active() &&
        !_app.isClosed &&
        !_app.state.globalLoading &&
        !_app.state.sessionRecoveryRequired &&
        _app.state.sessionRevision == _session.sessionRevision &&
        _app.state.profileId == _session.profileId &&
        _app.state.server == _session.server &&
        identical(db, _owner) &&
        db.profileId == _profileId &&
        identical(service, _api) &&
        identical(NetworkProxy.instance.config, _proxy) &&
        !NetworkProxy.instance.isChanging;

    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      if (!sameConnection()) throw const _ChannelSearchRetired();
      final route = _route ??
          BackendPlayback(await _api.preparePlaybackServer(
              serverOverride: _session.server));
      Future<void> check() async {
        if (!sameConnection()) throw const _ChannelSearchRetired();
        final current = await _owner.getCurrentlySelectedServer();
        if (!sameConnection() || !route.matchesConnection(current)) {
          throw const _ChannelSearchRetired();
        }
      }

      await check();
      if (!sameConnection()) throw const _ChannelSearchRetired();
      _route = route;
      final result = await _api.searchChannelVideos(
        widget.channelId,
        query,
        server: route.server,
        page: page,
        beforeRequest: check,
      );
      await check();
      if (!sameConnection()) throw const _ChannelSearchRetired();
      setState(() {
        for (final video in result.videos) {
          _results.putIfAbsent(video.videoId, () => video);
        }
        _hasMore =
            result.rawCount > 0 && _page < Service.channelSearchMaximumPage;
        _page++;
        _loading = false;
      });
    } on _ChannelSearchRetired {
      if (active()) widget.onClose();
    } catch (_) {
      if (active() && !sameConnection()) {
        widget.onClose();
      } else if (active()) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: widget.onClose,
          icon: const Icon(Icons.close_rounded),
        ),
        titleSpacing: 0,
        title: TextField(
          key: const ValueKey('channel-search-query'),
          autofocus: true,
          focusNode: _focus,
          controller: _field,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: locals.channelSearch,
            filled: true,
            isDense: true,
            fillColor: colors.surfaceContainerHighest,
            contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 10, 8, 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none),
          ),
        ),
        actions: [
          IconButton(
            tooltip: locals.search,
            onPressed: () => _submit(_field.text),
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: CommunityBrowse<Video>(
          items: _results.values.where((video) => !video.filterHide).toList(),
          match: videoCommunityMatches,
          builder: (context, videos, notice) => CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              if (_loading)
                const SliverToBoxAdapter(
                    child: LinearProgressIndicator(minHeight: 2)),
              if (notice != null) SliverToBoxAdapter(child: notice),
              if (videos.isNotEmpty) _ChannelSearchCards(videos: videos),
              if (_query.isNotEmpty && !_loading)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    child: Column(
                      children: [
                        if (_error)
                          Text(locals.itemlistErrorGeneric)
                        else if (videos.isEmpty)
                          Text(locals.nVideos(0)),
                        if (_error || _hasMore)
                          TextButton.icon(
                            onPressed: _loadPage,
                            icon: Icon(_error
                                ? Icons.refresh_rounded
                                : Icons.expand_more_rounded),
                            label:
                                Text(_error ? locals.retry : locals.loadMore),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelSearchCards extends StatelessWidget {
  final List<Video> videos;

  const _ChannelSearchCards({required this.videos});

  @override
  Widget build(BuildContext context) {
    Widget card(BuildContext context, int index) {
      final video = videos[index];
      return VideoListItem(
        key: ValueKey(video.videoId),
        video: video,
        layout: VideoCardLayout.flowFeed,
        showCommunityLabels: true,
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final columns = (width / 320).floor().clamp(1, 4);
          if (columns == 1) {
            return SliverList.separated(
              itemCount: videos.length,
              itemBuilder: card,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
            );
          }
          final tileWidth = (width - (columns - 1) * 12) / columns;
          final scale = MediaQuery.textScalerOf(context);
          return SliverGrid.builder(
            itemCount: videos.length,
            itemBuilder: card,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              mainAxisExtent: tileWidth * 9 / 16 +
                  scale.scale(16) * 2.45 +
                  scale.scale(12) * 1.5 +
                  32,
            ),
          );
        },
      ),
    );
  }
}

class _ChannelSearchRetired implements Exception {
  const _ChannelSearchRetired();
}
