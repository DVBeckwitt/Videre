import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/interfaces/db.dart';
import '../../../utils/models/paginated_list.dart';
import '../../models/subscription_group.dart';
import 'subscription_group_editor.dart';

class SubscriptionFeedGroups extends StatelessWidget {
  final bool autofocus;
  final Widget Function(
      BuildContext context, SubscriptionVideoList feed, Widget filters) builder;

  const SubscriptionFeedGroups(
      {super.key, required this.builder, this.autofocus = false});

  @override
  Widget build(BuildContext context) {
    final profileId = db.profileId;
    return _ProfileSubscriptionFeedGroups(
        key: ValueKey(profileId),
        database: db.forProfile(profileId),
        autofocus: autofocus,
        builder: builder);
  }
}

enum _BuiltInFilter { all, ungrouped }

class _ProfileSubscriptionFeedGroups extends StatefulWidget {
  final IDbClient database;
  final bool autofocus;
  final Widget Function(
      BuildContext context, SubscriptionVideoList feed, Widget filters) builder;

  const _ProfileSubscriptionFeedGroups(
      {super.key,
      required this.database,
      required this.autofocus,
      required this.builder});

  @override
  State<_ProfileSubscriptionFeedGroups> createState() =>
      _ProfileSubscriptionFeedGroupsState();
}

class _ProfileSubscriptionFeedGroupsState
    extends State<_ProfileSubscriptionFeedGroups> {
  final _filter = ValueNotifier<SubscriptionChannelFilter?>(null);
  late final _feed = SubscriptionVideoList(channelFilter: _filter);
  late StreamSubscription<List<SubscriptionGroup>> _subscription;
  List<SubscriptionGroup> _groups = [];
  Object _selected = _BuiltInFilter.all;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _watchGroups();
  }

  void _watchGroups() {
    _subscription = widget.database.watchSubscriptionGroups().listen((groups) {
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _hasError = false;
        if (_selected is String &&
            !_groups.any((group) => group.id == _selected)) {
          _selected = _BuiltInFilter.all;
        }
        _updateFilter();
      });
    }, onError: (Object error, StackTrace stack) {
      if (mounted) setState(() => _hasError = true);
    });
  }

  Future<void> _retryGroups() async {
    if (!_hasError) return;
    setState(() => _hasError = false);
    await _subscription.cancel();
    if (mounted) _watchGroups();
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    _filter.dispose();
    super.dispose();
  }

  void _updateFilter() {
    final selected = _selected;
    _filter.value = switch (selected) {
      _BuiltInFilter.all => null,
      _BuiltInFilter.ungrouped => (
          channelIds: {for (final group in _groups) ...group.channelIds},
          exclude: true,
        ),
      _ => (
          channelIds:
              _groups.firstWhere((group) => group.id == selected).channelIds,
          exclude: false,
        ),
    };
  }

  Widget _chip(String label, Object selection) => ChoiceChip(
        key: ValueKey(selection),
        autofocus: widget.autofocus && selection == _BuiltInFilter.all,
        label: Text(label),
        selected: _selected == selection,
        onSelected: (selected) {
          if (selected) {
            setState(() {
              _selected = selection;
              _updateFilter();
            });
          }
        },
      );

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final filters = Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.accept): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.open): ActivateIntent(),
      },
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: Row(
                spacing: 8,
                children: [
                  _chip(locals.subscriptionGroupsAll, _BuiltInFilter.all),
                  _chip(locals.subscriptionGroupsUngrouped,
                      _BuiltInFilter.ungrouped),
                  for (final group in _groups) _chip(group.name, group.id),
                ],
              ),
            ),
          ),
          if (_hasError)
            IconButton(
                onPressed: _retryGroups,
                tooltip: locals.retry,
                icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            tooltip: locals.subscriptionGroupsManage,
            icon: const Icon(Icons.edit),
            onSelected: (id) {
              final group =
                  _groups.where((group) => group.id == id).firstOrNull;
              if (id.isEmpty || group != null) {
                showSubscriptionGroupEditor(context,
                    database: widget.database, group: group);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: '', child: Text(locals.subscriptionGroupNew)),
              for (final group in _groups)
                PopupMenuItem(value: group.id, child: Text(group.name)),
            ],
          ),
        ],
      ),
    );
    return widget.builder(context, _feed, filters);
  }
}
