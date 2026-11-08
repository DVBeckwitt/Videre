import 'package:clipious/settings/views/components/server_account_dialogs.dart';
import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:gap/gap.dart';
import 'package:clipious/settings/views/tv/screens/settings.dart';
import 'package:clipious/settings/views/components/backend_picker.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/watch_sync_status.dart';
import 'package:clipious/settings/views/components/nerdvpn_access_settings.dart';
import 'package:clipious/network/nerdvpn_access.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';

import '../../../../app/states/app.dart';
import '../../../../utils.dart';
import '../../../../utils/views/tv/components/tv_text_field.dart';
import '../../../models/db/server.dart';
import '../../../states/server_settings.dart';

@RoutePage()
class TvManageSingleServerScreen extends StatelessWidget {
  final Server server;

  const TvManageSingleServerScreen({super.key, required this.server});

  void showAddHeaderDialog(BuildContext context) =>
      showServerHeaderDialog(context, television: true);

  void showBasicAuthDialog(BuildContext context) => showServerBasicAuthDialog(
      context,
      (key, value) => context.read<ServerSettingsCubit>().addHeader(key, value),
      television: true);

  void showLogInWithCookiesDialog(BuildContext context) async {
    var locals = AppLocalizations.of(context)!;
    var textTheme = Theme.of(context).textTheme;
    TextEditingController userController = TextEditingController();
    TextEditingController passwordController = TextEditingController();
    FocusNode focusNode = FocusNode();
    ColorScheme colors = Theme.of(context).colorScheme;

    var cubit = context.read<ServerSettingsCubit>();

    showTvDialog(
        context: context,
        builder: (BuildContext context) => [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: TvTextField(
                        leading: Icon(
                          Icons.person,
                          color: colors.secondary,
                        ),
                        autofocus: true,
                        focusNode: focusNode,
                        textInputAction: TextInputAction.next,
                        controller: userController,
                        autocorrect: false,
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email
                        ],
                        decoration: InputDecoration(
                            label: Text(
                          locals.username,
                          style: TextStyle(color: colors.secondary),
                        ))),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: TvTextField(
                      leading: Icon(
                        Icons.password,
                        color: colors.secondary,
                      ),
                      obscureText: true,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      controller: passwordController,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                          label: Text(
                        locals.password,
                        style: TextStyle(color: colors.secondary),
                      )),
                    ),
                  ),
                ],
              )
            ],
        actions: [
          TvButton(
            onPressed: (context) {
              Navigator.of(context).pop();
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
              child: Text(locals.cancel),
            ),
          ),
          TvButton(
            onPressed: (context) async {
              if (cubit.state.authenticating) return;
              try {
                await cubit.logInWithCookie(
                    userController.text, passwordController.text);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              } catch (_) {
                if (context.mounted) {
                  showTvAlertdialog(context, locals.error, [
                    Text(
                      locals.accountActionFailed,
                      style: textTheme.titleLarge,
                    )
                  ]);
                }
              }
            },
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
              child: Text(locals.ok),
            ),
          ),
        ]);
  }

  Future<void> _accountAction(
          BuildContext context, Future<void> Function() action) =>
      runServerAccountAction(context, action, television: true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TvOverscan(
        child: BlocProvider(
          create: (BuildContext context) => ServerSettingsCubit(
              ServerSettingsState(server: server), context.read<AppCubit>()),
          child: BlocBuilder<ServerSettingsCubit, ServerSettingsState>(
              builder: (context, state) {
            var server = state.server;
            var cubit = context.read<ServerSettingsCubit>();
            AppLocalizations locals = AppLocalizations.of(context)!;
            bool isLoggedIn =
                (server.authToken != null && server.authToken!.isNotEmpty) ||
                    (server.sidCookie != null && server.sidCookie!.isNotEmpty);

            return ListView(
              children: [
                SettingsTitle(
                    title: server.name.isEmpty ? server.url : server.name),
                SettingsTile(
                  title: locals.accountName,
                  description: server.name.isEmpty ? server.url : server.name,
                  leading: const Icon(Icons.badge_outlined),
                  onSelected: (context) async {
                    final name = await showProfileNameDialog(context,
                        title: locals.accountName,
                        label: locals.accountName,
                        initialName: server.name);
                    if (name != null && context.mounted) {
                      await _accountAction(
                          context, () => cubit.renameAccount(name));
                    }
                  },
                ),
                SettingsTile(
                  enabled: !server.inUse,
                  title: locals.useThisServer,
                  onSelected: (context) =>
                      _accountAction(context, () => cubit.useServer(true)),
                  autofocus: true,
                  trailing: Switch(
                      onChanged: server.inUse ? null : (value) {},
                      value: server.inUse),
                ),
                SettingsTitle(title: locals.backend),
                SettingsTile(
                  key: const ValueKey('backend-setting'),
                  title: backendLabel(context, server),
                  description: locals.backendHelp,
                  leading: const Icon(Icons.dns_outlined),
                  trailing: const Icon(Icons.chevron_right),
                  onSelected: (context) => showBackendPicker(
                    context,
                    server: server,
                    onDiscover: cubit.discoverBackends,
                    onDiscoverFromPage: (uri, source) => cubit
                        .discoverBrowserBackends(pageUri: uri, source: source),
                    onSave: cubit.setBackend,
                  ),
                ),
                SettingsTitle(title: locals.authentication),
                WatchSyncStatus(account: server),
                if (NerdVpnAccess.supports(server))
                  NerdVpnAccessSettings(
                    account: server,
                    authenticating: state.authenticating,
                    onCheck: cubit.checkApiAccess,
                    onSaveKey: cubit.setApiKey,
                  ),
                SettingsTile(
                  title: locals.protectedServerSignIn,
                  enabled: !state.authenticating,
                  description: locals.protectedServerSignInDescription,
                  leading: const Icon(Icons.shield_outlined),
                  onSelected: (context) =>
                      _accountAction(context, cubit.logInProtected),
                ),
                SettingsTile(
                  title: locals.cookieLogin,
                  enabled: !state.authenticating &&
                      !isLoggedIn &&
                      !NerdVpnAccess.supports(server),
                  onSelected: (context) => showLogInWithCookiesDialog(context),
                ),
                SettingsTile(
                  title: locals.logout,
                  enabled: isLoggedIn || NerdVpnAccess.supports(server),
                  onSelected: (context) =>
                      _accountAction(context, cubit.logOut),
                ),
                SettingsTitle(title: locals.customHeaders),
                ...state.server.customHeaders.keys.map((k) {
                  String value = state.server.customHeaders[k] ?? '';
                  if (k.toLowerCase() == 'authorization' ||
                      k.toLowerCase() == 'x-invidious-token') {
                    value = "········";
                  }

                  return SettingsTile(
                    title: k,
                    description: value,
                    onSelected: (context) => cubit.removeHeader(k),
                    trailing: const Icon(Icons.delete),
                  );
                }),
                SettingsTile(
                  title: locals.addBasicAuth,
                  leading: const Icon(Icons.key),
                  onSelected: (context) => showBasicAuthDialog(context),
                ),
                SettingsTile(
                  title: locals.addHeader,
                  leading: const Icon(Icons.add),
                  onSelected: showAddHeaderDialog,
                ),
                const Gap(20),
                SettingsTile(
                  title: locals.delete,
                  enabled: state.canDelete,
                  onSelected: (context) => _accountAction(context, () async {
                    final route = ModalRoute.of(context);
                    await cubit.deleteServer();
                    if (context.mounted && (route?.isCurrent ?? false)) {
                      Navigator.of(context).pop();
                    }
                  }),
                )
              ],
            );
          }),
        ),
      ),
    );
  }
}
