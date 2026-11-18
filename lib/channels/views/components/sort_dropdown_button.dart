import 'package:flutter/material.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/channels/models/channel_sort_by.dart';

class SortDropdownButton extends StatelessWidget {
  final ChannelSortBy selectedSortingOption;
  final Function(ChannelSortBy) onChanged;

  const SortDropdownButton({
    super.key,
    required this.selectedSortingOption,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    // Flow ChannelFilterBar.kt represents a sort group as one menu chip.
    return PopupMenuButton<ChannelSortBy>(
      tooltip: locals.searchSortBy,
      initialValue: selectedSortingOption,
      itemBuilder: (_) => ChannelSortBy.values
          .map((value) => PopupMenuItem<ChannelSortBy>(
                value: value,
                child: Text(value.getLabel(locals)),
              ))
          .toList(),
      onSelected: onChanged,
      child: Chip(
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(selectedSortingOption.getLabel(locals)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 18),
        ]),
      ),
    );
  }
}
