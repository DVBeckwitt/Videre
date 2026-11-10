import 'package:clipious/utils/motion.dart';
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
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/settings/models/errors/cannot_add_server_error.dart';
import 'package:clipious/settings/models/errors/invidious_service_error.dart';
import 'package:clipious/settings/models/errors/missing_software_key.dart';
import 'package:clipious/settings/models/errors/server_already_exists.dart';
import 'package:clipious/settings/models/errors/wrong_thumbnail_url.dart';
import 'package:clipious/settings/states/add_server.dart';
import 'package:clipious/settings/views/components/public_instances.dart';
import 'package:clipious/settings/views/components/profile_picker.dart';
import 'package:clipious/settings/views/components/nerdvpn_onion_setup.dart';
import 'package:clipious/settings/views/components/server_account_dialogs.dart';
import 'package:clipious/settings/views/screens/network_proxy.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/views/components/conditional_wrap.dart';
import 'package:clipious/utils/views/components/external_link.dart';

import '../../../network/nerdvpn_access.dart';
import '../../services/gateway_auth.dart';

@RoutePage()
class AddServerScreen extends StatelessWidget {
  const AddServerScreen({super.key});

  static const instancesUrl = 'https://docs.invidious.io/instances/';

  static Future<void> _openExternalUrl(
          BuildContext context, Uri url, String title, String help) =>
      openExternalLink(context, url, title: title, help: help);

  static Future<void> openInstanceDirectory(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return _openExternalUrl(context, Uri.parse(instancesUrl),
        locals.findPublicInstance, locals.instanceDirectoryHelp);
  }

  static Uri? instanceBrowserUrl(Server server, {String? videoId}) {
    final address = AddServerCubit.normalizeUrl(server.url);
    if (address == null) return null;
    final uri = Uri.parse(address);
    return videoId == null || videoId.isEmpty
        ? uri
        : uri.replace(
            path: '${uri.path}/watch',
            queryParameters: {'v': videoId, 'local': 'true'});
  }

  static String connectionAdvice(Object error, AppLocalizations locals) {
    if (error is NerdVpnAccessRequired && error.state == 'waiting') {
      return locals.nerdVpnAccessPending;
    }
    if (error is GatewayUnsupported ||
        error is GatewaySignInFailed ||
        error is NerdVpnAccessRequired) {
      return error.toString();
    }
    if (error is InvidiousServiceError) {
      if (error.isRateLimited) {
        final delay = error.retryAfter;
        return delay != null && delay > Duration.zero
            ? locals
                .instanceRetryAfterHelp((delay.inMilliseconds / 1000).ceil())
            : locals.instanceRateLimitedHelp;
      }
      if (error.statusCode == 401) return locals.instanceUnauthorizedHelp;
      if (error.responseWasHtml) return locals.instanceBrowserChallengeHelp;
      if (error.statusCode == 403) return locals.instanceForbiddenHelp;
      if (error.statusCode != null &&
          error.statusCode! >= 200 &&
          error.statusCode! < 300) {
        return locals.instanceInvalidResponseHelp;
      }
    }
    if (error is TypeError) return locals.instanceInvalidResponseHelp;
    if (error is NerdVpnApiKeyException) return error.message;
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

  static Future<void> showConnectionHelp(BuildContext context,
      {String? videoId}) async {
    final locals = AppLocalizations.of(context)!;
    bool testing = false;
    String? result;
    Server? selectedServer;
    try {
      selectedServer = await db.getCurrentlySelectedServer();
    } catch (error) {
      result = connectionAdvice(error, locals);
    }
    if (!context.mounted) return;
    // Keep retries and browser links on the instance that failed.
    final server = selectedServer;
    final browserUrl =
        server == null ? null : instanceBrowserUrl(server, videoId: videoId);
    if (server != null && browserUrl == null) {
      result = locals.instanceAddressInvalid;
    }
    final manage = await showDialog<bool>(
        animationStyle: AppMotion.dialogStyle(context),
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
                          onPressed: testing ||
                                  server == null ||
                                  browserUrl == null
                              ? null
                              : () async {
                                  update(() {
                                    testing = true;
                                    result = null;
                                  });
                                  try {
                                    await service
                                        .validateServer(server.url,
                                            server.headersForUrl(server.url))
                                        .timeout(const Duration(seconds: 15));
                                    if (!context.mounted) return;
                                    await service
                                        .getVideo(
                                            videoId == null || videoId.isEmpty
                                                ? 'dQw4w9WgXcQ'
                                                : videoId,
                                            serverOverride: server)
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
                          onPressed: () => Navigator.of(context).pop(true),
                          child: Text(locals.chooseInstance)),
                      if (browserUrl != null)
                        TextButton(
                            onPressed: () => _openExternalUrl(
                                context,
                                browserUrl,
                                locals.externalLinkTitle,
                                locals.instanceBrowserHelp),
                            child: Text(locals.externalLinkTitle)),
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
    showServerKeyValueDialog(context,
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

  void showBasicAuthDialog(BuildContext context) => showServerBasicAuthDialog(
      context,
      (key, value) => context.read<AddServerCubit>().addHeader(key, value));

  static void handleError(BuildContext context, dynamic e) {
    var locals = AppLocalizations.of(context)!;
    const wikiUrl =
        'https://github.com/lamarios/clipious/wiki/Common-Issues#video-thumbnails-not-working';
    final errorMessage = e is WrongThumbnailUrl && isTv
        ? '${e.getLabel(locals)}\n\n$wikiUrl'
        : e is CannotAddServerError
            ? e.getLabel(locals)
            : e is NerdVpnApiKeyException
                ? e.message
                : e.toString();
    final advice = connectionAdvice(e, locals);
    final approvalPending = e is NerdVpnAccessRequired && e.state == 'waiting';
    List<Widget> actions = [
      if (e is WrongThumbnailUrl && !isTv)
        TextButton(
            onPressed: () {
              unawaited(openExternalLink(context, Uri.parse(wikiUrl)));
            },
            child: Text(locals.openWikiLink)),
      TextButton(
          onPressed: () => Navigator.of(context).pop(), child: Text(locals.ok))
    ];

    showAlertDialog(
        context,
        approvalPending ? locals.nerdVpnApprovalPending : locals.error,
        [
          Text(advice),
          if (!approvalPending && errorMessage != advice) ...[
            const Gap(12),
            Text(errorMessage, style: Theme.of(context).textTheme.bodySmall),
          ],
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
        actions: [
          IconButton(
            tooltip: locals.profiles,
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => showProfilePicker(context),
          ),
          IconButton(
            tooltip: locals.networkProxy,
            icon: const Icon(Icons.vpn_lock_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const NetworkProxySettingsScreen())),
          ),
        ],
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
                      ValueListenableBuilder(
                        valueListenable: cubit.urlController,
                        builder: (context, _, __) => Text(cubit.usesNerdVpnOnion
                            ? locals.nerdVpnOnionSetup
                            : cubit.usesNerdVpn
                                ? locals.nerdVpnAccessSignIn
                                : locals.instanceAddressDescription),
                      ),
                      const Gap(12),
                      const PublicInstancesButton(
                          openDirectory: openInstanceDirectory),
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
                      ValueListenableBuilder(
                        valueListenable: cubit.urlController,
                        builder: (context, _, __) => cubit.usesNerdVpn
                            ? const SizedBox.shrink()
                            : Column(children: [
                                const Gap(10),
                                TextField(
                                  controller: cubit.nameController,
                                  readOnly: state.loading,
                                  maxLength: 80,
                                  decoration: InputDecoration(
                                      labelText: locals.accountName),
                                ),
                              ]),
                      ),
                      ValueListenableBuilder(
                        valueListenable: cubit.urlController,
                        builder: (context, _, __) => cubit.usesNerdVpnOnion
                            ? NerdVpnOnionSetup(
                                serverUrl: AddServerCubit.normalizeUrl(
                                    cubit.urlController.text)!,
                                apiKeyController: cubit.apiKeyController,
                                loading: state.loading,
                              )
                            : SwitchListTile(
                                title: Text(locals.protectedServer),
                                subtitle: Text(locals.protectedServerHelp),
                                value: state.protectedServer,
                                onChanged: state.loading
                                    ? null
                                    : cubit.setProtectedServer,
                              ),
                      ),
                      ListTile(
                        leading: AnimatedRotation(
                            duration: AppMotion.duration(context),
                            curve: animationCurve,
                            turns: state.showAdvanced ? 0.5 : 0,
                            child: const Icon(Icons.expand_less)),
                        title: Text(locals.advancedConfiguration),
                        onTap: state.loading
                            ? null
                            : () => cubit.setShowAdvanced(!state.showAdvanced),
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
                                if (k.toLowerCase() == 'authorization' ||
                                    k.toLowerCase() == 'x-invidious-token') {
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
                                duration: AppMotion.duration(context))
                            .fade(
                                begin: 0,
                                end: 1,
                                curve: animationCurve,
                                duration: AppMotion.fadeDuration(context),
                                delay: AppMotion.fadeDuration(
                                    context, animationDuration ~/ 4)),
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
                                  child: MotionLoadingIndicator(
                                      child: CircularProgressIndicator(
                                    strokeWidth: 1,
                                  )))
                              : ValueListenableBuilder(
                                  valueListenable: cubit.urlController,
                                  builder: (context, _, __) => Text(cubit
                                              .usesNerdVpn &&
                                          !cubit.usesNerdVpnOnion &&
                                          (state.protectedServer ||
                                              !state.headers.keys.any(
                                                  NerdVpnAccess.isKeyHeader))
                                      ? locals.nerdVpnSignInAndAdd
                                      : locals.testAndAddServer),
                                )),
                      ValueListenableBuilder(
                        valueListenable: cubit.urlController,
                        builder: (context, _, __) => cubit.usesNerdVpnOnion
                            ? const SizedBox.shrink()
                            : CheckboxListTile(
                                title: Text(
                                  locals.alsoTestServerConfig,
                                  style: textTheme.bodySmall,
                                ),
                                value: state.advancedTest,
                                onChanged: state.loading ||
                                        state.publicInstance != null
                                    ? null
                                    : (value) =>
                                        cubit.setAdvancedTest(value ?? true),
                              ),
                      ),
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
