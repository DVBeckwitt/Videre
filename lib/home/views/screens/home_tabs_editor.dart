import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../recommendations/candidate_sources.dart';
import '../../../recommendations/recommendation_service.dart';
import '../../../settings/states/settings.dart';
import '../../models/home_tabs_layout.dart';

class HomeTabsEditorScreen extends StatefulWidget {
  final List<RecommendationInterest> interests;
  final bool includeYourFeeds;

  const HomeTabsEditorScreen(
      {super.key, this.interests = const [], this.includeYourFeeds = true});

  @override
  State<HomeTabsEditorScreen> createState() => _HomeTabsEditorScreenState();
}

class _HomeTabsEditorScreenState extends State<HomeTabsEditorScreen> {
  late final String _profile = db.profileId;
  late final AppCubit _app = context.read<AppCubit>();
  late final int _session = _app.state.sessionRevision;
  late List<RecommendationInterest> _interests = List.of(widget.interests);
  bool _saving = false;
  bool _loadingTopics = false;

  bool get _current =>
      mounted &&
      !_app.isClosed &&
      db.profileId == _profile &&
      _app.state.sessionRevision == _session &&
      !_app.state.globalLoading &&
      !_app.state.sessionRecoveryRequired;

  @override
  void initState() {
    super.initState();
    // Settings can open this editor without mounting a Home feed first. Use
    // only the local candidate pool to obtain the current topic labels.
    if (_interests.isEmpty) unawaited(_loadTopics());
  }

  Future<void> _loadTopics() async {
    _loadingTopics = true;
    try {
      final candidates =
          RecommendationCandidates(db, isCurrent: () => _current);
      final videos = candidates.localVideos();
      if (!_current) return;
      final result = await RecommendationService.forProfile(db, _profile)
          .rankVideos(videos, surface: 'home');
      if (_current && !result.cancelled) {
        setState(() => _interests = result.interests);
      }
    } on Object {
      // Fixed tabs remain editable when the local engine is unavailable.
    } finally {
      if (mounted) setState(() => _loadingTopics = false);
    }
  }

  Future<void> _save(HomeTabsLayout layout) async {
    if (!_current || _saving) return;
    setState(() => _saving = true);
    try {
      await context.read<SettingsCubit>().setHomeTabsLayout(layout);
    } on Object {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.homeTabsSaveError)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<String> _completeOrder(
          HomeTabsLayout layout, Iterable<String> available) =>
      List.of(layout.enabledOrder ?? available);

  void _toggle(
      HomeTabsLayout layout, List<String> available, String id, bool on) {
    final order = _completeOrder(layout, available)..remove(id);
    if (on) order.add(id);
    unawaited(_save(HomeTabsLayout(
        enabledOrder: order, continueWatching: layout.continueWatching)));
  }

  void _reorder(HomeTabsLayout layout, List<String> available,
      List<String> visible, int from, int to) {
    if (to > from) to--;
    if (to == from) return;
    final id = visible[from];
    final remainingVisible = List.of(visible)..removeAt(from);
    final before = to < remainingVisible.length ? remainingVisible[to] : null;
    // Keep preferences for temporarily unavailable topics while moving a
    // visible item. Hidden topics must not erase the user's saved order.
    final order = _completeOrder(layout, available)..remove(id);
    order.insert(before == null ? order.length : order.indexOf(before), id);
    unawaited(_save(HomeTabsLayout(
        enabledOrder: order, continueWatching: layout.continueWatching)));
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    context.watch<AppCubit>();
    final layout = context.watch<SettingsCubit>().state.homeTabsLayout;
    final labels = <String, String>{
      HomeTabsLayout.forYou: locals.flowForYou,
      if (widget.includeYourFeeds)
        HomeTabsLayout.yourFeeds: locals.flowYourFeeds,
      HomeTabsLayout.discover: locals.flowDiscoverVideos,
      for (final interest in _interests)
        HomeTabsLayout.topicId(interest.id): interest.label,
    };
    final available = labels.keys.toList();
    final visible = layout.orderedIds(available);
    final hidden = available.where((id) => !visible.contains(id)).toList();
    final enabled = _current && !_saving;
    return Scaffold(
      appBar: AppBar(title: Text(locals.homeTabs)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(locals.homeTabsHelp),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const ValueKey('home-continue-watching-toggle'),
              contentPadding: EdgeInsets.zero,
              title: Text(locals.flowContinueWatching),
              subtitle: Text(locals.homeContinueWatchingHint),
              value: layout.continueWatching,
              onChanged: enabled
                  ? (value) => _save(HomeTabsLayout(
                      enabledOrder: layout.enabledOrder,
                      continueWatching: value))
                  : null,
            ),
            const Divider(),
            Text(locals.homeTabsShown,
                style: Theme.of(context).textTheme.titleMedium),
            if (visible.isEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(locals.homeTabsEmpty)),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: visible.length,
              onReorder: (from, to) {
                if (enabled) _reorder(layout, available, visible, from, to);
              },
              itemBuilder: (context, index) {
                final id = visible[index];
                return Row(key: ValueKey('home-tab-row-$id'), children: [
                  if (enabled)
                    ReorderableDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(Icons.drag_handle,
                            semanticLabel: locals.phoneNavigationMove),
                      ),
                    ),
                  Expanded(
                    child: SwitchListTile(
                      key: ValueKey('home-tabs-toggle-$id'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(labels[id]!),
                      value: true,
                      onChanged: enabled
                          ? (on) => _toggle(layout, available, id, on)
                          : null,
                    ),
                  ),
                  PopupMenuButton<bool>(
                    key: ValueKey('home-tabs-move-$id'),
                    enabled: enabled && visible.length > 1,
                    tooltip: locals.phoneNavigationMove,
                    onSelected: (earlier) => _reorder(layout, available,
                        visible, index, earlier ? index - 1 : index + 2),
                    itemBuilder: (_) => [
                      if (index > 0)
                        PopupMenuItem(
                            value: true,
                            child: Text(locals.phoneNavigationEarlier)),
                      if (index < visible.length - 1)
                        PopupMenuItem(
                            value: false,
                            child: Text(locals.phoneNavigationLater)),
                    ],
                  ),
                ]);
              },
            ),
            if (hidden.isNotEmpty) ...[
              const Divider(),
              Text(locals.homeTabsHidden,
                  style: Theme.of(context).textTheme.titleMedium),
              for (final id in hidden)
                SwitchListTile(
                  key: ValueKey('home-tabs-toggle-$id'),
                  title: Text(labels[id]!),
                  value: false,
                  onChanged: enabled
                      ? (on) => _toggle(layout, available, id, on)
                      : null,
                ),
            ],
            if (_loadingTopics)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator())
            else if (_interests.isEmpty)
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(locals.homeTabsTopicsHint)),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, children: [
              TextButton(
                key: const ValueKey('home-tabs-hide-all'),
                // Saved topics may be absent from this device's current
                // catalog. Hide all must retire them too, so they stay hidden
                // if the topic becomes available again.
                onPressed:
                    enabled && _completeOrder(layout, available).isNotEmpty
                        ? () => _save(HomeTabsLayout(
                            enabledOrder: const [],
                            continueWatching: layout.continueWatching))
                        : null,
                child: Text(locals.homeTabsHideAll),
              ),
              TextButton(
                key: const ValueKey('home-tabs-reset'),
                onPressed: enabled
                    ? () => _save(HomeTabsLayout(
                        continueWatching: layout.continueWatching))
                    : null,
                child: Text(locals.homeTabsReset),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
