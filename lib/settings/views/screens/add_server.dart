import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/main.dart';
import 'package:clipious/router.dart';
import 'package:clipious/settings/models/errors/cannot_add_server_error.dart';
import 'package:clipious/settings/models/errors/missing_software_key.dart';
import 'package:clipious/settings/models/errors/server_already_exists.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/views/screens/manage_single_server.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/conditional_wrap.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../utils/string.dart';

@RoutePage()
class AddServerScreen extends StatelessWidget {
  const AddServerScreen({super.key});

  static const instancesUrl = 'https://docs.invidious.io/instances/';

  static Future<void> openInstanceDirectory(BuildContext context) async {
    try {
      if (!isTv &&
          await launchUrl(Uri.parse(instancesUrl),
              mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // TVs and devices without a browser can still show the address.
    }
    if (context.mounted) {
      final locals = AppLocalizations.of(context)!;
      await showAlertDialog(context, locals.findPublicInstance, [
        Text(locals.instanceDirectoryHelp),
        const SelectableText(instancesUrl),
      ]);
    }
  }

  static String connectionAdvice(Object error, AppLocalizations locals) {
    if (error is FormatException) return locals.instanceAddressInvalid;
    if (error is ServerAlreadyExists) {
      return locals.instanceAlreadySavedHelp;
    }
    if (error is TimeoutException) {
      return locals.instanceTimeoutHelp;
    }
    if (error is MissingSoftwareKeyError) {
      return locals.instanceApiHelp;
    }
    if (error is WrongThumbnailUrl) {
      return locals.instanceThumbnailHelp;
    }
    return locals.instanceConnectionHelp;
  }

  static Future<void> showConnectionHelp(BuildContext context) async {
    final locals = AppLocalizations.of(context)!;
    bool testing = false;
    String? result;
    final manage = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title: Text(locals.connectionHelp),
                    content: SingleChildScrollView(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(locals.connectionHelpDescription),
                        const Gap(12),
                        Text(locals.instanceAccountSeparation),
                        if (result != null) ...[const Gap(12), Text(result!)],
                      ],
                    )),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(locals.cancel)),
                      TextButton(
                          onPressed: testing
                              ? null
                              : () async {
                                  update(() {
                                    testing = true;
                                    result = null;
                                  });
                                  try {
                                    final server =
                                        await db.getCurrentlySelectedServer();
                                    await service
                                        .validateServer(
                                            server.url, server.customHeaders)
                                        .timeout(const Duration(seconds: 15));
                                    result = locals.instanceReachable;
                                  } catch (error) {
                                    result = connectionAdvice(error, locals);
                                  }
                                  if (context.mounted) {
                                    update(() => testing = false);
                                  }
                                },
                          child: Text(testing
                              ? locals.testingConnection
                              : locals.testConnection)),
                      TextButton(
                          onPressed: testing
                              ? null
                              : () => Navigator.of(context).pop(true),
                          child: Text(locals.chooseInstance)),
                    ],
                  ));
        });
    if (manage == true && context.mounted) {
      await AutoRouter.of(context).push(isTv
          ? const TvSettingsManageServersRoute()
          : const ManageServersRoute());
    }
  }

  void showAddHeaderDialog(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ManageSingleServerScreen.showKeyValueDialog(context,
        field1Title: locals.name,
        field2Title: locals.value,
        field2Secret: false,
        okText: locals.add, onOk: (key, value) async {
      var cubit = context.read<AddServerCubit>();
      await cubit.addHeader(key, value);
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  void showBasicAuthDialog(BuildContext context) {
    var locals = AppLocalizations.of(context)!;
    ManageSingleServerScreen.showKeyValueDialog(context,
        field1Title: locals.username,
        field2Title: locals.password,
        field1AutofillHints: const [
          AutofillHints.username,
          AutofillHints.email
        ],
        field2AutofillHints: const [AutofillHints.password],
        field2Secret: true,
        okText: locals.add, onOk: (username, password) async {
      var cubit = context.read<AddServerCubit>();

      await cubit.addHeader(
          "Authorization", 'Basic ${encodeBase64('$username:$password')}');
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  static void handleError(BuildContext context, dynamic e) {
    var locals = AppLocalizations.of(context)!;
    const wikiUrl =
        'https://github.com/lamarios/clipious/wiki/Common-Issues#video-thumbnails-not-working';
    final errorMessage = e is WrongThumbnailUrl && isTv
        ? '${e.getLabel(locals)}\n\n$wikiUrl'
        : e is CannotAddServerError
            ? e.getLabel(locals)
            : e.toString();
    List<Widget> actions = [
      if (e is WrongThumbnailUrl && !isTv)
        TextButton(
            onPressed: () {
              launchUrl(Uri.parse(wikiUrl));
            },
            child: Text(locals.openWikiLink)),
      TextButton(
          onPressed: () => Navigator.of(context).pop(), child: Text(locals.ok))
    ];

    showAlertDialog(
        context,
        locals.error,
        [
          Text(connectionAdvice(e, locals)),
          const Gap(12),
          Text(errorMessage, style: Theme.of(context).textTheme.bodySmall),
        ],
        actions: actions);
  }

  @override
  Widget build(BuildContext context) {
    var locals = AppLocalizations.of(context)!;

    final textTheme = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final device = getDeviceType();
    return Scaffold(
      appBar: AppBar(
        title: Text(locals.addServer),
      ),
      body: SafeArea(
        bottom: false,
        child: ConditionalWrap(
          wrapIf: device == DeviceType.tablet,
          wrapper: (child) => Align(
            alignment: Alignment.topCenter,
            child: Container(
                constraints: const BoxConstraints(maxWidth: 500), child: child),
          ),
          child: BlocProvider(
            create: (BuildContext context) =>
                AddServerCubit(const AddServerState()),
            child: BlocBuilder<AddServerCubit, AddServerState>(
                builder: (context, state) {
              final cubit = context.read<AddServerCubit>();
              return Padding(
                padding: const EdgeInsets.all(8.0),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(locals.instanceAddressDescription),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => openInstanceDirectory(context),
                            icon: const Icon(Icons.open_in_new),
                            label: Text(locals.findPublicInstance),
                          )),
                      TextField(
                        controller: cubit.urlController,
                        keyboardType: TextInputType.url,
                        readOnly: state.loading,
                        decoration: InputDecoration(
                          labelText: locals.instanceAddress,
                          hintText: 'https://invidious.example',
                          helperText: locals.instanceAddressHelp,
                          helperMaxLines: 2,
                          errorText: cubit.urlController.text != 'https://' &&
                                  !state.valid
                              ? locals.instanceAddressError
                              : null,
                          errorMaxLines: 2,
                        ),
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                      ),
                      const Gap(10),
                      ListTile(
                        leading: AnimatedRotation(
                            duration: animationDuration,
                            curve: animationCurve,
                            turns: state.showAdvanced ? 0.5 : 0,
                            child: const Icon(Icons.expand_less)),
                        title: Text(locals.advancedConfiguration),
                        onTap: () => cubit.setShowAdvanced(!state.showAdvanced),
                      ),
                      if (state.showAdvanced)
                        Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                              Text(
                                locals.customHeaders,
                                style: textTheme.bodyLarge
                                    ?.copyWith(color: colors.primary),
                              ),
                              Text(locals.customHeadersExplanation,
                                  style: textTheme.bodySmall),
                              const Gap(10),
                              ...state.headers.keys.map((k) {
                                String display = state.headers[k] ?? '';
                                if (k == 'Authorization') {
                                  display = "········";
                                }

                                return ListTile(
                                  title: Text(k),
                                  subtitle: Text(display),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete),
                                    onPressed: () => cubit.removeHeader(k),
                                  ),
                                );
                              }),
                              ListTile(
                                leading: const Icon(Icons.key),
                                title: Text(locals.addBasicAuth),
                                onTap: () => showBasicAuthDialog(context),
                              ),
                              ListTile(
                                leading: const Icon(Icons.add),
                                title: Text(locals.addHeader),
                                onTap: () => showAddHeaderDialog(context),
                              )
                            ])
                            .animate()
                            .slideY(
                                begin: -0.2,
                                end: 0,
                                curve: animationCurve,
                                duration: animationDuration)
                            .fade(
                                begin: 0,
                                end: 1,
                                curve: animationCurve,
                                duration: animationDuration,
                                delay: animationDuration ~/ 4),
                      FilledButton.tonal(
                          onPressed: state.loading || !state.valid
                              ? null
                              : () async {
                                  try {
                                    final server = await cubit.validateServer();

                                    if (server != null && context.mounted) {
                                      AutoRouter.of(context).maybePop(server);
                                    }
                                  } catch (e) {
                                    if (context.mounted) {
                                      handleError(context, e);
                                    }
                                  }
                                },
                          child: state.loading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1,
                                  ))
                              : Text(locals.testAndAddServer)),
                      CheckboxListTile(
                        title: Text(
                          locals.alsoTestServerConfig,
                          style: textTheme.bodySmall,
                        ),
                        value: state.advancedTest,
                        onChanged: (value) =>
                            cubit.setAdvancedTest(value ?? true),
                      )
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
