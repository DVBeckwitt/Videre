import 'package:auto_route/auto_route.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/server_list_settings.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:settings_ui/settings_ui.dart';

import '../../models/db/server.dart';
import '../screens/settings.dart';

class ManagerServersView extends StatelessWidget {
  const ManagerServersView({super.key});

  Future<void> openServer(BuildContext context, Server s) async {
    var cubit = context.read<ServerListSettingsCubit>();
    await AutoRouter.of(context).push(ManageSingleServerRoute(server: s));
    await cubit.refreshServers();
  }

  Future<void> addServer(BuildContext context) async {
    var cubit = context.read<ServerListSettingsCubit>();
    final server = await AutoRouter.of(context).push(const AddServerRoute());
    if (server != null && server is Server && context.mounted) {
      await cubit.saveServer(server);
    }
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    SettingsThemeData theme = settingsTheme(colorScheme);
    var locals = AppLocalizations.of(context)!;

    return BlocBuilder<ServerListSettingsCubit, ServerListSettingsState>(
      builder: (ctx, state) {
        SettingsCubit settings = context.watch<SettingsCubit>();
        ServerListSettingsCubit cubit = context.read<ServerListSettingsCubit>();
        return Stack(
          children: [
            SettingsList(
              lightTheme: theme,
              darkTheme: theme,
              sections: [
                SettingsSection(
                  tiles: [
                    SettingsTile.switchTile(
                      title: Text(locals.skipSslVerification),
                      description: Text(locals.skipSslVerificationDescription),
                      initialValue: settings.state.skipSslVerification,
                      onToggle: settings.toggleSslVerification,
                    )
                  ],
                ),
                SettingsSection(
                    title: Text(locals.yourServers),
                    tiles: state.dbServers.isNotEmpty
                        ? state.dbServers
                            .map((s) => SettingsTile(
                                  leading: InkWell(
                                    onTap: () => cubit.switchServer(s),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: Icon(
                                        Icons.done,
                                        color: s.inUse
                                            ? colorScheme.primary
                                            : colorScheme.secondaryContainer,
                                      ),
                                    ),
                                  ),
                                  title: Text(s.url),
                                  value: Text(
                                      '${cubit.isLoggedInToServer(s.url) ? '${locals.loggedIn}, ' : ''} ${locals.tapToManage}'),
                                  onPressed: (context) =>
                                      openServer(context, s),
                                ))
                            .toList()
                        : [
                            SettingsTile(
                              title: Text(locals.addServer),
                              enabled: false,
                            )
                          ]),
              ],
            ),
            Positioned(
              right: 20,
              bottom: 20,
              child: FloatingActionButton(
                onPressed: () => addServer(context),
                backgroundColor: colorScheme.primaryContainer,
                child: const Icon(Icons.add),
              ),
            )
          ],
        );
      },
    );
  }
}
