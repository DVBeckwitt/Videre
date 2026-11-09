import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/content_mode.dart';

/// The two browsing modes share playback but retain separate navigation.
class ContentModeSelector extends StatelessWidget {
  final HomeContentMode value;
  final ValueChanged<HomeContentMode> onChanged;

  const ContentModeSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return LayoutBuilder(builder: (context, constraints) {
      final showIcons = constraints.maxWidth >= 210 &&
          MediaQuery.textScalerOf(context).scale(14) <= 18;
      return Semantics(
        label: locals.contentMode,
        child: SegmentedButton<HomeContentMode>(
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            textStyle: Theme.of(context).textTheme.labelLarge,
          ),
          segments: [
            ButtonSegment(
              value: HomeContentMode.videos,
              icon: showIcons ? const Icon(Icons.smart_display_outlined) : null,
              label: Text(locals.videos,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              tooltip: locals.videos,
            ),
            ButtonSegment(
              value: HomeContentMode.music,
              icon: showIcons ? const Icon(Icons.music_note_outlined) : null,
              label: Text(locals.music,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              tooltip: locals.music,
            ),
          ],
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.single),
        ),
      );
    });
  }
}
