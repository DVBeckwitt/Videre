import 'package:clipious/utils/motion.dart';
import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/router.dart';

import '../../../settings/states/settings.dart';
import '../../../home/views/components/flow_video_home.dart';
import '../../models/search_date.dart';
import '../components/search_filters.dart';
import '../components/search_suggestions_panel.dart';
import '../../states/search.dart';

//Do not change, invidious doesn't allow any specific value, it's to make the paginated lists work as expected
const searchPageSize = 20;

@RoutePage()
class SearchScreen extends StatefulWidget {
  final String? query;
  final bool? searchNow;

  const SearchScreen({super.key, this.query, this.searchNow});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _queryFocus = FocusNode();

  @override
  void dispose() {
    _queryFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<SettingsCubit>();
    return BlocProvider(
      create: (_) => SearchCubit<SearchState>(
          SearchState.init(query: widget.query, searchNow: widget.searchNow),
          settings),
      child: BlocBuilder<SearchCubit, SearchState>(builder: (context, state) {
        final locals = AppLocalizations.of(context)!;
        final search = context.read<SearchCubit>();
        void submit(String query) {
          if (query.trim().isEmpty) return;
          _queryFocus.unfocus();
          search.setSearchQuery(query);
        }

        bool restore() {
          if (!search.restoreResults()) return false;
          _queryFocus.unfocus();
          return true;
        }

        return AutoTabsRouter.tabBar(
          animatePageTransition: AppMotion.allowsMovement(context),
          physics: const NeverScrollableScrollPhysics(),
          routes: const [
            SearchVideoRoute(),
            SearchChannelRoute(),
            SearchPlaylistRoute(),
          ],
          builder: (context, child, controller) {
            final tabs = AutoTabsRouter.of(context);
            final hasQuery = search.submittedQuery.isNotEmpty;
            return PopScope(
              canPop: !search.canRestoreResults,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) restore();
              },
              child: Scaffold(
                appBar: AppBar(
                  leading: BackButton(onPressed: () {
                    if (!restore()) context.router.maybePop();
                  }),
                  titleSpacing: 0,
                  title: TextField(
                    decoration: InputDecoration(
                      hintText: locals.search,
                      filled: true,
                      fillColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      isDense: true,
                      contentPadding:
                          const EdgeInsetsDirectional.fromSTEB(16, 11, 6, 11),
                      border: OutlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    autofocus: widget.query == null,
                    focusNode: _queryFocus,
                    controller: state.queryController,
                    textInputAction: TextInputAction.search,
                    onTap: search.editQuery,
                    onSubmitted: submit,
                  ),
                  actions: [
                    IconButton(
                      tooltip:
                          MaterialLocalizations.of(context).closeButtonTooltip,
                      onPressed: () {
                        if (search.searchCleared()) {
                          if (!restore()) context.router.maybePop();
                        } else {
                          _queryFocus.requestFocus();
                        }
                      },
                      icon: const Icon(Icons.clear),
                    ),
                    if (state.showResults)
                      SearchFiltersButton(
                        initialFilters: state.filters,
                        onChanged: search.onFiltersChanged,
                      ),
                    if (state.showResults && tabs.activeIndex == 0)
                      // Flow SearchTopBar.kt: change presentation in place.
                      ValueListenableBuilder<bool>(
                        valueListenable: search.compactResults,
                        builder: (context, compact, _) => IconButton(
                          tooltip: compact
                              ? locals.searchStackedView
                              : locals.searchCompactView,
                          onPressed: search.toggleResultLayout,
                          icon:
                              Icon(compact ? Icons.grid_view : Icons.view_list),
                        ),
                      ),
                  ],
                ),
                body: SafeArea(
                  child: IndexedStack(
                    index: state.showResults ? 0 : 1,
                    children: [
                      // Flow SearchScreen.kt retains the result grid while the
                      // query is edited so Back restores the same scroll position.
                      ExcludeFocus(
                        excluding: !state.showResults,
                        child: TickerMode(
                          enabled: state.showResults,
                          child: hasQuery
                              ? Column(children: [
                                  _SearchFilterChips(
                                    selected: tabs.activeIndex,
                                    onTypeChanged: tabs.setActiveIndex,
                                    recent:
                                        state.filters.date == SearchDate.week,
                                    onRecentChanged: (enabled) =>
                                        search.onFiltersChanged(
                                      state.filters.copyWith(
                                          date: enabled
                                              ? SearchDate.week
                                              : SearchDate.any),
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: innerHorizontalPadding),
                                      child: child,
                                    ),
                                  ),
                                ])
                              : const SizedBox.shrink(),
                        ),
                      ),
                      ExcludeFocus(
                        excluding: state.showResults,
                        child: SearchSuggestionsPanel(
                          query: state.queryController.text,
                          history: state.searchHistory,
                          suggestions: state.suggestions,
                          onSubmit: submit,
                          onFill: (value) {
                            state.queryController.value = TextEditingValue(
                                text: value,
                                selection: TextSelection.collapsed(
                                    offset: value.length));
                            _queryFocus.requestFocus();
                          },
                          onDelete: search.removeFromHistory,
                          onClearHistory: search.clearHistory,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }
}

// Flow SearchFilterBar.kt's result-type and recent-upload chip row. Videre
// exposes the types and server-side date filter its catalog already supports.
class _SearchFilterChips extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onTypeChanged;
  final bool recent;
  final ValueChanged<bool> onRecentChanged;

  const _SearchFilterChips({
    required this.selected,
    required this.onTypeChanged,
    required this.recent,
    required this.onRecentChanged,
  });

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final types = [locals.videos, locals.channels, locals.playlists];
    return FlowHomeChipStrip(chips: [
      for (var index = 0; index < types.length; index++)
        ChoiceChip(
          label: Text(types[index]),
          selected: selected == index,
          onSelected: (_) => onTypeChanged(index),
        ),
      if (selected == 0)
        FilterChip(
          label: Text(locals.searchUploadDateWeek),
          selected: recent,
          onSelected: onRecentChanged,
        ),
    ]);
  }
}
