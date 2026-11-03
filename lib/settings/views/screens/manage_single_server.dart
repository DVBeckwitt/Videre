import 'package:clipious/utils/motion.dart';
import 'package:auto_route/annotations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/app/states/app.dart';
import 'package:clipious/settings/states/server_settings.dart';
import 'package:clipious/settings/views/components/backend_picker.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/watch_sync_status.dart';
import 'package:clipious/settings/services/gateway_auth.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/string.dart';
import 'package:settings_ui/settings_ui.dart';

import '../../models/db/server.dart';
import 'settings.dart';

@RoutePage()
class ManageSingleServerScreen extends StatelessWidget {
  final Server server;

  const ManageSingleServerScreen({super.key, required this.server});

  static Future<void> showKeyValueDialog(
    BuildContext context, {
    required String field1Title,
    required String field2Title,
    bool field1Secret = false,
    bool field2Secret = false,
    List<String>? field1AutofillHints,
    List<String>? field2AutofillHints,
    required String okText,
    required Function(String field1, String field2) onOk,
  }) {
    var locals = AppLocalizations.of(context)!;
    TextEditingController field1Controller = TextEditingController();
    TextEditingController field2Controller = TextEditingController();

    return showDialog<void>(
      animationStyle: AppMotion.dialogStyle(context),
      context: context,
      useRootNavigator: false,
      builder: (BuildContext context) {
        return AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: field1Controller,
                  autocorrect: false,
                  autofillHints: field1AutofillHints,
                  obscureText: field1Secret,
                  decoration: InputDecoration(label: Text(field1Title))),
              TextField(
                obscureText: field2Secret,
                autocorrect: false,
                controller: field2Controller,
                autofillHints: field2AutofillHints,
                decoration: InputDecoration(label: Text(field2Title)),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              child: Text(locals.cancel),
              onPressed: () {
                //Put your code here which you want to execute on Cancel button click.
                Navigator.of(context).pop();
              },
            ),
            TextButton(
                child: Text(okText),
                onPressed: () =>
                    onOk(field1Controller.text, field2Controller.text)),
          ],
        );
      },
    );
  }

  void showAddHeaderDialog(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    showKeyValueDialog(context,
        field1Title: locals.name,
        field2Title: locals.value,
        okText: locals.add, onOk: (key, value) async {
      var cubit = context.read<ServerSettingsCubit>();
      await cubit.addHeader(key, value);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  void showBasicAuthDialog(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    showKeyValueDialog(context,
        field1Title: locals.username,
        field2Title: locals.password,
        field1AutofillHints: const [
          AutofillHints.username,
          AutofillHints.email
        ],
        field2AutofillHints: const [AutofillHints.password],
        field2Secret: true,
        okText: locals.add, onOk: (username, password) async {
      var cubit = context.read<ServerSettingsCubit>();

      await cubit.addHeader(
          "Authorization", 'Basic ${encodeBase64('$username:$password')}');
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  void showLogInWithCookiesDialog(BuildContext context) async {
    var locals = AppLocalizations.of(context)!;
    var dialogOpen = true;
    showKeyValueDialog(context,
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

  Future<void> _accountAction(
      BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        final locals = AppLocalizations.of(context)!;
        await showAlertDialog(context, locals.error, [
          Text(error is GatewayUnsupported
              ? error.toString()
              : locals.accountActionFailed)
        ]);
      }
    }
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
                              await _accountAction(
                                  context, () => cubit.renameAccount(name));
                            }
                          },
                        ),
                        SettingsTile.switchTile(
                          initialValue: server.inUse,
                          onToggle: (value) => _accountAction(
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
                            SettingsTile.navigation(
                              leading: const Icon(Icons.shield_outlined),
                              enabled: !state.authenticating,
                              title: Text(locals.protectedServerSignIn),
                              description:
                                  Text(locals.protectedServerSignInDescription),
                              onPressed: (context) =>
                                  _accountAction(context, cubit.logInProtected),
                            ),
                            SettingsTile(
                              leading: server.authToken?.isNotEmpty ?? false
                                  ? const Icon(Icons.check)
                                  : const Icon(Icons.token),
                              enabled: !state.authenticating &&
                                  !isLoggedIn &&
                                  !state.hasBasicAuth,
                              title: Text(locals.tokenLogin),
                              value: Text(server.authToken?.isNotEmpty ?? false
                                  ? locals.loggedIn
                                  : locals.tokenLoginDescription),
                              onPressed: (context) =>
                                  _accountAction(context, cubit.logInWithToken),
                            ),
                            SettingsTile(
                              leading: server.sidCookie?.isNotEmpty ?? false
                                  ? const Icon(Icons.check)
                                  : const Icon(Icons.cookie_outlined),
                              enabled: !state.authenticating && !isLoggedIn,
                              title: Text(locals.cookieLogin),
                              value: Text(server.sidCookie?.isNotEmpty ?? false
                                  ? locals.loggedIn
                                  : locals.cookieLoginDescription),
                              onPressed: showLogInWithCookiesDialog,
                            ),
                            SettingsTile(
                              leading: const Icon(Icons.exit_to_app),
                              enabled: isLoggedIn,
                              title: Text(locals.logout),
                              onPressed: (context) =>
                                  _accountAction(context, cubit.logOut),
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
                              if (k == 'Authorization') {
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
                              _accountAction(context, () async {
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
