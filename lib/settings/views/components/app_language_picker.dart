import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/app_languages.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../utils/views/components/select_list_dialog.dart';
import '../../states/settings.dart';

void showAppLanguagePicker(BuildContext context, {bool television = false}) {
  final locals = AppLocalizations.of(context)!;
  final settings = context.read<SettingsCubit>();
  final choices = {
    locals.followSystem: null,
    for (final entry in nativeLanguageNames.entries) entry.value: entry.key,
  };
  final labels = choices.keys.toList();
  final selected = settings.getLocaleDisplayName() ?? locals.followSystem;
  void choose(String label) => settings.setLocale(choices[label]);

  if (television) {
    AutoRouter.of(context).push(TvSelectFromListRoute(
      title: locals.appLanguage,
      options: labels,
      selected: selected,
      onSelect: choose,
    ));
  } else {
    final colors = Theme.of(context).colorScheme;
    SelectList.show<String>(context,
        title: locals.appLanguage,
        values: labels,
        value: selected,
        itemBuilder: (label, selected) => Text(label,
            style: TextStyle(color: selected ? colors.primary : null)),
        onSelect: choose);
  }
}
