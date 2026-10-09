import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/states/server_list_settings.dart';
import 'package:clipious/settings/views/components/manager_server_inner.dart';
import 'package:clipious/utils/views/components/app_icon.dart';
import 'package:clipious/welcome_wizard/states/welcome_wizard.dart';

import '../../../settings/models/db/server.dart';

@RoutePage()
class WelcomeWizardScreen extends StatelessWidget {
  const WelcomeWizardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colors = Theme.of(context).colorScheme;
    var textTheme = Theme.of(context).textTheme;

    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (context) => WelcomeWizardCubit(null)),
        BlocProvider(
          create: (context) => ServerListSettingsCubit(
              ServerListSettingsState(dbServers: []), context.read<AppCubit>()),
        )
      ],
      child: BlocListener<ServerListSettingsCubit, ServerListSettingsState>(
        listener: (context, state) {
          context.read<WelcomeWizardCubit>().getSelectedServer();
        },
        child: BlocBuilder<WelcomeWizardCubit, Server?>(
          builder: (context, server) {
            var cubit = context.read<WelcomeWizardCubit>();
            return Scaffold(
              extendBodyBehindAppBar: true,
              backgroundColor: colors.surface,
              body: SafeArea(
                  top: true,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(width: 72, height: 72, child: AppIcon()),
                        Text(
                          'Videre',
                          style: textTheme.displaySmall
                              ?.copyWith(color: colors.primary),
                        ),
                        Expanded(
                          child: server == null
                              ? ListView(
                                  padding: const EdgeInsets.all(16),
                                  children: [
                                    Text(locals.setupConnectionTitle,
                                        style: textTheme.titleLarge),
                                    const SizedBox(height: 12),
                                    Text(locals.setupInstanceDescription),
                                    const SizedBox(height: 16),
                                    ListTile(
                                      leading: const Icon(Icons.public),
                                      title: Text(locals.findPublicInstance),
                                      subtitle: Text(
                                          locals.setupDirectoryDescription),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => const ManagerServersView()
                                          .addServer(context),
                                    ),
                                    ListTile(
                                      leading: const Icon(Icons.dns_outlined),
                                      title: Text(locals.enterInstanceAddress),
                                      subtitle:
                                          Text(locals.setupAddressDescription),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => const ManagerServersView()
                                          .addServer(context),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(locals.setupInstanceAvailability),
                                  ],
                                )
                              : const ManagerServersView(showAdvanced: false),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: FilledButton.tonal(
                              onPressed: server != null
                                  ? () {
                                      AutoRouter.of(context)
                                          .replace(const MainRoute())
                                          .then((value) =>
                                              cubit.getSelectedServer());
                                    }
                                  : null,
                              child: Text(locals.startUsingClipious)),
                        )
                      ])),
            );
          },
        ),
      ),
    );
  }
}
