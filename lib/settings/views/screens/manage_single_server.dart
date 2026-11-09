import 'package:clipious/settings/views/components/server_account_dialogs.dart';
import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/settings/views/components/backend_picker.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/watch_sync_status.dart';
import 'package:clipious/settings/views/components/nerdvpn_access_settings.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/utils.dart';
import 'package:settings_ui/settings_ui.dart';

import '../../models/db/server.dart';
import 'settings.dart';

@RoutePage()
class ManageSingleServerScreen extends StatelessWidget {
  final Server server;

  const ManageSingleServerScreen({super.key, required this.server});

  void showAddHeaderDialog(BuildContext context) =>
      showServerHeaderDialog(context);

  void showBasicAuthDialog(BuildContext context) => showServerBasicAuthDialog(
      context,
      (key, value) =>
          context.read<ServerSettingsCubit>().addHeader(key, value));

  void showLogInWithCookiesDialog(BuildContext context) async {
    var locals = AppLocalizations.of(context)!;
    var dialogOpen = true;
    showServerKeyValueDialog(context,
        field1Title: locals.username,
        field2Title: locals.password,
        field1AutofillHints: const [
          AutofillHints.username,
          AutofillHints.email
        ],
        field2AutofillHints: const [AutofillHints.password],
        field2Secret: true,
        okText: locals.ok, onOk: (username, password) async {
      var cubit = context.read<ServerSettingsCubit>();
      if (cubit.state.authenticating) return;
      try {
        await cubit.logInWithCookie(username, password);
        if (dialogOpen && context.mounted) {
          Navigator.of(context).pop();
        }
      } catch (_) {
        if (dialogOpen && context.mounted) {
          showAlertDialog(
              context, locals.error, [Text(locals.accountActionFailed)]);
        }
      }
    }).whenComplete(() => dialogOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    SettingsThemeData theme = settingsTheme(colorScheme);

    return BlocProvider(
      create: (context) => ServerSettingsCubit(
          ServerSettingsState(server: server), context.read<AppCubit>()),
      child: BlocBuilder<ServerSettingsCubit, ServerSettingsState>(
        builder: (context, state) {
          var server = state.server;
          var cubit = context.read<ServerSettingsCubit>();
          bool isLoggedIn =
              (server.authToken != null && server.authToken!.isNotEmpty) ||
                  (server.sidCookie != null && server.sidCookie!.isNotEmpty);
          return Scaffold(
              appBar: AppBar(
                title: Text(server.name.isEmpty ? server.url : server.name),
              ),
              backgroundColor: colorScheme.surface,
              body: SafeArea(
                bottom: false,
                child: SettingsList(
                    lightTheme: theme,
                    darkTheme: theme,
                    sections: [
                      SettingsSection(tiles: [
                        SettingsTile.navigation(
                          title: Text(locals.accountName),
                          value: Text(
                              server.name.isEmpty ? server.url : server.name),
                          leading: const Icon(Icons.badge_outlined),
                          onPressed: (context) async {
                            final name = await showProfileNameDialog(context,
                                title: locals.accountName,
                                label: locals.accountName,
                                initialName: server.name);
                            if (name != null && context.mounted) {
                              await runServerAccountAction(
                                  context, () => cubit.renameAccount(name));
                            }
                          },
                        ),
                        SettingsTile.switchTile(
                          initialValue: server.inUse,
                          onToggle: (value) => runServerAccountAction(
                              context, () => cubit.useServer(value)),
                          title: Text(locals.useThisServer),
                          enabled: !server.inUse,
                        )
                      ]),
                      SettingsSection(
                        title: Text(locals.backend),
                        tiles: [
                          SettingsTile.navigation(
                            key: const ValueKey('backend-setting'),
                            leading: const Icon(Icons.dns_outlined),
                            title: Text(backendLabel(context, server)),
                            description: Text(locals.backendHelp),
                            onPressed: (context) => showBackendPicker(
                              context,
                              server: server,
                              onDiscover: cubit.discoverBackends,
                              onDiscoverFromPage: (uri, source) =>
                                  cubit.discoverBrowserBackends(
                                      pageUri: uri, source: source),
                              onSave: cubit.setBackend,
                            ),
                          ),
                        ],
                      ),
                      SettingsSection(
                          title: Text(locals.authentication),
                          tiles: [
                            CustomSettingsTile(
                                child: WatchSyncStatus(account: server)),
                            if (NerdVpnAccess.supports(server))
                              CustomSettingsTile(
                                child: NerdVpnAccessSettings(
                                  account: server,
                                  authenticating: state.authenticating,
                                  onCheck: cubit.checkApiAccess,
                                  onSaveKey: cubit.setApiKey,
                                ),
                              ),
                            if (!(NerdVpnAccess.supports(server) &&
                                isNerdVpnOnionUrl(server.url))) ...[
                              SettingsTile.navigation(
                                leading: const Icon(Icons.shield_outlined),
                                enabled: !state.authenticating,
                                title: Text(locals.protectedServerSignIn),
                                description: Text(
                                    locals.protectedServerSignInDescription),
                                onPressed: (context) => runServerAccountAction(
                                    context, cubit.logInProtected),
                              ),
                              SettingsTile(
                                leading: server.authToken?.isNotEmpty ?? false
                                    ? const Icon(Icons.check)
                                    : const Icon(Icons.token),
                                enabled: !state.authenticating &&
                                    (!isLoggedIn ||
                                        NerdVpnAccess.supports(server)) &&
                                    !state.hasBasicAuth,
                                title: Text(locals.tokenLogin),
                                value: Text(
                                    server.authToken?.isNotEmpty ?? false
                                        ? locals.loggedIn
                                        : locals.tokenLoginDescription),
                                onPressed: (context) => runServerAccountAction(
                                    context, cubit.logInWithToken),
                              ),
                              SettingsTile(
                                leading: server.sidCookie?.isNotEmpty ?? false
                                    ? const Icon(Icons.check)
                                    : const Icon(Icons.cookie_outlined),
                                enabled: !state.authenticating &&
                                    !isLoggedIn &&
                                    !NerdVpnAccess.supports(server),
                                title: Text(locals.cookieLogin),
                                value: Text(
                                    server.sidCookie?.isNotEmpty ?? false
                                        ? locals.loggedIn
                                        : locals.cookieLoginDescription),
                                onPressed: showLogInWithCookiesDialog,
                              ),
                            ],
                            SettingsTile(
                              leading: const Icon(Icons.exit_to_app),
                              enabled:
                                  isLoggedIn || NerdVpnAccess.supports(server),
                              title: Text(locals.logout),
                              onPressed: (context) =>
                                  runServerAccountAction(context, cubit.logOut),
                            )
                          ]),
                      SettingsSection(
                          title: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(locals.customHeaders),
                              Text(
                                locals.customHeadersExplanation,
                                style: TextStyle(
                                    color: theme.tileDescriptionTextColor),
                              )
                            ],
                          ),
                          tiles: [
                            ...state.server.customHeaders.keys.map((k) {
                              String value =
                                  state.server.customHeaders[k] ?? '';
                              if (k.toLowerCase() == 'authorization' ||
                                  k.toLowerCase() == 'x-invidious-token') {
                                value = "········";
                              }

                              return SettingsTile(
                                title: Text(k),
                                description: Text(value),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete),
                                  onPressed: () => cubit.removeHeader(k),
                                ),
                              );
                            }),
                            SettingsTile(
                              title: Text(locals.addBasicAuth),
                              leading: const Icon(Icons.key),
                              onPressed: showBasicAuthDialog,
                            ),
                            SettingsTile(
                              title: Text(locals.addHeader),
                              leading: const Icon(Icons.add),
                              onPressed: showAddHeaderDialog,
                            )
                          ]),
                      SettingsSection(title: const Text(''), tiles: [
                        SettingsTile(
                          enabled: state.canDelete,
                          onPressed: (context) =>
                              runServerAccountAction(context, () async {
                            final route = ModalRoute.of(context);
                            await cubit.deleteServer();
                            if (context.mounted &&
                                (route?.isCurrent ?? false)) {
                              Navigator.of(context).pop();
                            }
                          }),
                          leading: Icon(
                            Icons.delete,
                            color: state.canDelete
                                ? Colors.red
                                : Colors.red.withValues(alpha: 0.5),
                          ),
                          title: Text(
                            locals.delete,
                            style: TextStyle(
                                color: state.canDelete
                                    ? Colors.red
                                    : Colors.red.withValues(alpha: 0.5)),
                          ),
                        )
                      ]),
                    ]),
              ));
        },
      ),
    );
  }
}
