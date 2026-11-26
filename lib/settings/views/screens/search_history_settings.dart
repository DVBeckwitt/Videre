import 'package:clipious/utils/motion.dart';
import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/settings/models/search_history_control.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:settings_ui/settings_ui.dart';

import 'settings.dart';

@RoutePage()
class SearchHistorySettingsScreen extends StatelessWidget {
  final SearchHistoryControl? _target;
  final FocusNode? _targetFocus;

  const SearchHistorySettingsScreen({super.key})
      : _target = null,
        _targetFocus = null;

  const SearchHistorySettingsScreen.focused(
    SearchHistoryControl target,
    FocusNode focusNode, {
    super.key,
  })  : _target = target,
        _targetFocus = focusNode;

  confirmClear(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    showDialog(
        animationStyle: AppMotion.dialogStyle(context),
        context: context,
        useRootNavigator: false,
        useSafeArea: true,
        builder: (ctx) => SizedBox(
            height: 200,
            child: AlertDialog(
                title: Text(locals.clearSearchHistory),
                content: Text(locals.irreversibleAction),
                actions: [
                  TextButton(
                    child: Text(locals.cancel),
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                  ),
                  TextButton(
                    child: Text(locals.ok),
                    onPressed: () async {
                      await db.clearSearchHistory();
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                  ),
                ])));
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    SettingsThemeData theme = settingsTheme(colorScheme);

    return BlocBuilder<SettingsCubit, SettingsState>(
      builder: (context, state) {
        var cubit = context.read<SettingsCubit>();
        return Scaffold(
            appBar: AppBar(
              title: Text(locals.searchHistory),
            ),
            backgroundColor: colorScheme.surface,
            body: SafeArea(
              bottom: false,
              child:
                  SettingsList(lightTheme: theme, darkTheme: theme, sections: [
                SettingsSection(
                    title: Text(locals.searchHistoryDescription),
                    tiles: [
                      CustomSettingsTile(
                        child: SwitchListTile.adaptive(
                          key: ValueKey(SearchHistoryControl.enable.id),
                          focusNode: _target == SearchHistoryControl.enable
                              ? _targetFocus
                              : null,
                          contentPadding: const EdgeInsetsDirectional.only(
                              start: 24, end: 8),
                          value: state.useSearchHistory,
                          onChanged: cubit.toggleSearchHistory,
                          title: Text(locals.enableSearchHistory),
                        ),
                      ),
                      SettingsTile(
                        enabled: state.useSearchHistory,
                        title: Text(locals.searchHistoryLimit),
                        description: Text(locals.searchHistoryLimitDescription),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                                onPressed: () => state.useSearchHistory
                                    ? cubit.changeSearchHistoryLimit(
                                        increase: false)
                                    : null,
                                icon: const Icon(Icons.remove)),
                            Text(state.searchHistoryLimit.toString()),
                            IconButton(
                                onPressed: () => state.useSearchHistory
                                    ? cubit.changeSearchHistoryLimit(
                                        increase: true)
                                    : null,
                                icon: const Icon(Icons.add)),
                          ],
                        ),
                      ),
                      CustomSettingsTile(
                        child: ListTile(
                          key: ValueKey(SearchHistoryControl.clear.id),
                          focusNode: _target == SearchHistoryControl.clear
                              ? _targetFocus
                              : null,
                          contentPadding: const EdgeInsetsDirectional.only(
                              start: 24, end: 8),
                          title: Text(locals.clearSearchHistory),
                          onTap: () => confirmClear(context),
                        ),
                      )
                    ])
              ]),
            ));
      },
    );
  }
}
