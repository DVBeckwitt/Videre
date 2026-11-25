// Presentation and action order ported from Flow's SearchSuggestionsPanel.kt
// at 565d1f7a. The inputs come from Videre's history and Invidious service.

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import 'search_history_matching.dart';

class SearchSuggestionsPanel extends StatefulWidget {
  final String query;
  final List<String> history;
  final List<String> suggestions;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String> onFill;
  final ValueChanged<String> onDelete;
  final Future<void> Function() onClearHistory;

  const SearchSuggestionsPanel({
    super.key,
    required this.query,
    required this.history,
    required this.suggestions,
    required this.onSubmit,
    required this.onFill,
    required this.onDelete,
    required this.onClearHistory,
  });

  @override
  State<SearchSuggestionsPanel> createState() => _SearchSuggestionsPanelState();
}

class _SearchSuggestionsPanelState extends State<SearchSuggestionsPanel> {
  bool _showAllHistory = false;

  Future<void> _clear() async {
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(locals.clearSearchHistory),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.clearSearchHistory)),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.onClearHistory();
      if (mounted) setState(() => _showAllHistory = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final history = recentOrMatchingSearches(widget.history, widget.query);
    final shown = _showAllHistory
        ? history
        : history.take(searchHistoryInitialRows).toList();
    final seen = {for (final item in history) item.trim().toLowerCase()};
    final suggestions = widget.suggestions
        .where((item) =>
            item.trim().isNotEmpty && seen.add(item.trim().toLowerCase()))
        .toList();
    return ListView(
      primary: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (shown.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 4, 0),
            child: Row(children: [
              Expanded(
                child: Text(locals.searchHistory,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              IconButton(
                tooltip: locals.clearSearchHistory,
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: _clear,
              ),
            ]),
          ),
        for (final item in shown)
          ListTile(
            leading: const Icon(Icons.history_rounded),
            title: Text(item, maxLines: 2, overflow: TextOverflow.ellipsis),
            onTap: () => widget.onSubmit(item),
            trailing: IconButton(
              tooltip: locals.delete,
              onPressed: () => widget.onDelete(item),
              icon: const Icon(Icons.close_rounded, size: 20),
            ),
          ),
        if (shown.length < history.length)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: 4),
              child: TextButton(
                onPressed: () => setState(() => _showAllHistory = true),
                child: Text(locals.loadMore),
              ),
            ),
          ),
        for (final item in suggestions)
          SearchSuggestionTile(
            suggestion: item,
            onSubmit: () => widget.onSubmit(item),
            onFill: () => widget.onFill(item),
          ),
      ],
    );
  }
}

class SearchSuggestionTile extends StatelessWidget {
  final String suggestion;
  final VoidCallback onSubmit;
  final VoidCallback onFill;

  const SearchSuggestionTile({
    super.key,
    required this.suggestion,
    required this.onSubmit,
    required this.onFill,
  });

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.search_rounded),
        title: Text(suggestion, maxLines: 2, overflow: TextOverflow.ellipsis),
        onTap: onSubmit,
        trailing: IconButton(
          tooltip: AppLocalizations.of(context)!.searchFillSuggestion,
          onPressed: onFill,
          icon: const Icon(Icons.north_west_rounded, size: 20),
        ),
      );
}
