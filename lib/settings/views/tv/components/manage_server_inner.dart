import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/settings.dart';

import '../../../models/db/server.dart';
import '../../../states/server_list_settings.dart';
import '../screens/settings.dart';

class TvManageServersInner extends StatelessWidget {
  const TvManageServersInner({super.key});

  Future<void> openServer(BuildContext context, Server s) async {
    var cubit = context.read<ServerListSettingsCubit>();
    await AutoRouter.of(context).push(TvManageSingleServerRoute(server: s));
    await cubit.refreshServers();
  }

  Future<void> addServer(BuildContext context) async {
    var cubit = context.read<ServerListSettingsCubit>();
    final server = await AutoRouter.of(context).push(const TvAddServerRoute());
    if (server != null && server is Server && context.mounted) {
      await cubit.saveServer(server);
    }
  }

  @override
  Widget build(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    AppLocalizations locals = AppLocalizations.of(context)!;
    return BlocBuilder<ServerListSettingsCubit, ServerListSettingsState>(
        builder: (context, state) {
      var cubit = context.read<ServerListSettingsCubit>();
      var settings = context.watch<SettingsCubit>();
      return ListView(children: [
        SettingsTile(
          title: locals.skipSslVerification,
          description: locals.skipSslVerification,
          onSelected: (context) => settings
              .toggleSslVerification(!settings.state.skipSslVerification),
          trailing: Switch(
              onChanged: (value) {}, value: settings.state.skipSslVerification),
        ),
        SettingsTitle(title: locals.yourServers),
        ...state.dbServers.map((s) => SettingsTile(
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
              title: s.url,
              description:
                  '${cubit.isLoggedInToServer(s.url) ? '${locals.loggedIn}, ' : ''} ${locals.tapToManage}',
              onSelected: (context) => openServer(context, s),
            )),
        SettingsTile(
          title: locals.addServer,
          leading: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(
              Icons.add,
              color: colorScheme.secondary,
            ),
          ),
          onSelected: (context) => addServer(context),
        ),
      ]);
    });
  }
}
