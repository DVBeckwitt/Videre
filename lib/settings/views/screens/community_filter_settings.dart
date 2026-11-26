import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/views/components/community_filter_choice.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';

void showCommunityFilterSettings(BuildContext context, {bool tv = false}) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => CommunityFilterSettingsScreen(tv: tv),
  ));
}

class CommunityFilterSettingsScreen extends StatelessWidget {
  final bool tv;
  final CommunityRule? focusRule;
  final FocusNode? ruleFocusNode;

  const CommunityFilterSettingsScreen({
    super.key,
    this.tv = false,
    this.focusRule,
    this.ruleFocusNode,
  });

  Future<void> _chooseAction(BuildContext context, CommunityRule rule) async {
    final filters = communityFilters;
    final profile = filters.profileSelection;
    final current = filters.action(rule);
    final selected = await chooseCommunityAction(context, rule, current);
    if (selected == null ||
        selected == current ||
        !context.mounted ||
        !identical(filters, communityFilters) ||
        profile != filters.profileSelection) {
      return;
    }
    await _saveChange(
      context,
      () => filters.setAction(rule, selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return _SettingsPage(
      title: locals.communityFilters,
      tv: tv,
      child: ListenableBuilder(
        listenable: communityFilters.changes,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ListBody(children: [
            for (final source in CommunityList.values) ...[
              _SourceDescription(key: ValueKey(source), source: source),
              for (final rule in _rulesFor(source))
                ListTile(
                  key: ValueKey(rule),
                  focusNode: focusRule == rule ? ruleFocusNode : null,
                  autofocus:
                      focusRule == null && rule == CommunityRule.youtubeBlock,
                  title: Text(communityRuleLabel(locals, rule)),
                  subtitle: Text(
                    communityActionLabel(locals, communityFilters.action(rule)),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _chooseAction(context, rule),
                ),
              if (communityFilters.enabled(source))
                _ListUpdateTile(
                    key: ValueKey((source, 'refresh')), source: source),
              ListTile(
                key: ValueKey((source, 'exceptions')),
                title: Text(locals.communityExceptions),
                subtitle: Text(locals.communityExceptionCount(
                  communityFilters.exceptions(source).length,
                )),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => _CommunityExceptions(tv: tv, source: source),
                )),
              ),
              if (source == CommunityList.aislist) const Divider(),
            ],
          ]),
        ),
      ),
    );
  }
}

Iterable<CommunityRule> _rulesFor(CommunityList source) =>
    CommunityRule.values.where((rule) => rule.source == source);

String _sourceLabel(AppLocalizations locals, CommunityList source) =>
    switch (source) {
      CommunityList.aislist => locals.communityYoutubeFilters,
      CommunityList.aimusic => locals.communityMusicFilter,
    };

Future<void> _saveChange(
    BuildContext context, Future<void> Function() change) async {
  try {
    await change();
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.communitySettingsFailed),
    ));
  }
}

class _SourceDescription extends StatelessWidget {
  final CommunityList source;

  const _SourceDescription({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final (scope, attribution) = switch (source) {
      CommunityList.aislist => (
          locals.communityYoutubeScope,
          locals.communityYoutubeAttribution,
        ),
      CommunityList.aimusic => (
          locals.communityMusicScope,
          locals.communityMusicAttribution,
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_sourceLabel(locals, source),
              style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(scope),
          const SizedBox(height: 4),
          Text(attribution, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ListUpdateTile extends StatelessWidget {
  final CommunityList source;

  const _ListUpdateTile({super.key, required this.source});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final status = communityFilters.status(source);
    final lastUpdated = status.lastUpdated?.toLocal();
    final material = MaterialLocalizations.of(context);
    final lastChecked = lastUpdated == null
        ? null
        : locals.communityListUpdated(
            '${material.formatMediumDate(lastUpdated)} '
            '${material.formatTimeOfDay(TimeOfDay.fromDateTime(lastUpdated), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}',
          );
    final state = status.refreshing
        ? locals.communityListLoading
        : status.failed
            ? (status.version == null
                ? locals.communityListUnavailable
                : locals.communityListStale)
            : (status.version == null ? locals.communityListPending : null);
    return ListTile(
      title: Text(locals.communityUpdateList),
      subtitle: Semantics(
        liveRegion: true,
        child: Text([
          if (state != null) state,
          if (lastChecked != null) lastChecked,
        ].join('\n')),
      ),
      trailing: status.refreshing
          ? const SizedBox.square(
              dimension: 20,
              child: MotionLoadingIndicator(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : const Icon(Icons.refresh),
      onTap: () async {
        if (communityFilters.status(source).refreshing) return;
        await _saveChange(context, () => communityFilters.refresh(source));
      },
    );
  }
}

class _CommunityExceptions extends StatelessWidget {
  final bool tv;
  final CommunityList source;

  const _CommunityExceptions({required this.tv, required this.source});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return _SettingsPage(
      title: locals.communityExceptions,
      tv: tv,
      child: ListenableBuilder(
        listenable: communityFilters.changes,
        builder: (context, _) {
          final filters = communityFilters;
          final profile = filters.profileSelection;
          final exceptions = filters.exceptions(source).toList()..sort();
          return ListView.builder(
            itemCount: 1 + exceptions.length,
            itemBuilder: (context, index) {
              if (index == 0) {
                return ListTile(
                  title: Text(_sourceLabel(locals, source)),
                  subtitle: Text(exceptions.isEmpty
                      ? locals.communityNoExceptions
                      : locals.communityExceptionCount(exceptions.length)),
                );
              }
              final identity = exceptions[index - 1];
              return ListTile(
                key: ValueKey(identity),
                autofocus: index == 1,
                title: Text(identity),
                subtitle: Text(locals.communityRemoveException),
                trailing: const Icon(Icons.remove_circle_outline),
                onTap: () async {
                  if (!identical(filters, communityFilters) ||
                      profile != filters.profileSelection) {
                    return;
                  }
                  await _saveChange(
                    context,
                    () => filters.removeException(source, identity),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  final String title;
  final bool tv;
  final Widget child;

  const _SettingsPage(
      {required this.title, required this.tv, required this.child});

  @override
  Widget build(BuildContext context) {
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: child,
      ),
    );
    return CommunityFilterShortcuts(
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(child: tv ? TvOverscan(child: content) : content),
      ),
    );
  }
}
