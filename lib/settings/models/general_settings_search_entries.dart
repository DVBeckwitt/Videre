import 'package:clipious/content_filter/community_filter.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/search_history_control.dart';
import 'package:clipious/settings/models/settings_search_entry.dart';
import 'package:clipious/settings/views/components/community_filter_choice.dart';
import 'package:clipious/settings/views/screens/community_filter_settings.dart';
import 'package:clipious/settings/views/screens/network_proxy.dart';
import 'package:clipious/settings/views/screens/search_history_settings.dart';
import 'package:clipious/settings/views/tv/screens/search_history_settings.dart';

List<SettingsSearchEntry> generalSettingsSearchEntries(
  AppLocalizations locals, {
  required bool television,
}) {
  return [
    for (final control in SearchHistoryControl.values)
      SettingsSearchEntry(
        id: control.id,
        title: switch (control) {
          SearchHistoryControl.enable => locals.enableSearchHistory,
          SearchHistoryControl.clear => locals.clearSearchHistory,
        },
        category: locals.searchHistory,
        keywords: [
          locals.browsing,
          switch (control) {
            SearchHistoryControl.enable =>
              locals.settingsSearchEnableSearchHistoryKeywords,
            SearchHistoryControl.clear =>
              locals.settingsSearchClearSearchHistoryKeywords,
          },
        ],
        destination: (_, focusNode) => television
            ? TvSearchHistorySettingsScreen.focused(control, focusNode)
            : SearchHistorySettingsScreen.focused(control, focusNode),
      ),
    SettingsSearchEntry(
      id: NetworkProxyControl.enable.id,
      title: locals.networkProxyEnable,
      category: locals.networkProxy,
      description: locals.networkProxyDescription,
      destination: (_, focusNode) => NetworkProxySettingsScreen.focused(
        NetworkProxyControl.enable,
        focusNode,
      ),
    ),
    SettingsSearchEntry(
      id: NetworkProxyControl.orbot.id,
      title: locals.networkProxyOrbotPreset,
      category: locals.networkProxy,
      description: locals.networkProxyOrbotHelp,
      destination: (_, focusNode) => NetworkProxySettingsScreen.focused(
        NetworkProxyControl.orbot,
        focusNode,
      ),
    ),
    for (final rule in CommunityRule.values)
      SettingsSearchEntry(
        id: 'community-filter-${rule.name}',
        title: communityRuleLabel(locals, rule),
        category: locals.communityFilters,
        description: rule == CommunityRule.music
            ? locals.communityMusicScope
            : locals.communityYoutubeScope,
        keywords: [
          locals.communityFiltersSummary,
          locals.communityActionLabel,
          locals.communityActionHide,
        ],
        destination: (_, focusNode) => CommunityFilterSettingsScreen(
          tv: television,
          focusRule: rule,
          ruleFocusNode: focusNode,
        ),
      ),
  ];
}
