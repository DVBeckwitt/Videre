import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:gap/gap.dart';

import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/motion.dart';
import '../../states/add_server.dart';
import 'nerdvpn_api_key_setup.dart';
import 'server_account_dialogs.dart';

class AddServerOptions extends StatelessWidget {
  final AddServerState state;
  final VoidCallback onSubmit;
  final bool television;

  const AddServerOptions({
    super.key,
    required this.state,
    required this.onSubmit,
    this.television = false,
  });

  void _showHeaderDialog(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    showServerKeyValueDialog(context,
        television: television,
        field1Title: locals.name,
        field2Title: locals.value,
        okText: locals.add, onOk: (dialogContext, key, value) async {
      final cubit = context.read<AddServerCubit>();
      await runServerAccountAction(dialogContext, () async {
        await cubit.addHeader(key, value);
        if (dialogContext.mounted &&
            ModalRoute.of(dialogContext)?.isCurrent == true) {
          Navigator.of(dialogContext).pop();
        }
      }, television: television);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<AddServerCubit>();
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final credentials =
        Listenable.merge([cubit.urlController, cubit.apiKeyController]);
    final gatewaySwitch = SwitchListTile(
      title: Text(locals.protectedServer),
      subtitle: Text(locals.protectedServerHelp),
      value: state.protectedServer,
      onChanged: state.loading ? null : cubit.setProtectedServer,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListenableBuilder(
          listenable: credentials,
          builder: (context, _) => Column(children: [
            if (cubit.usesNerdVpn)
              NerdVpnApiKeySetup(
                serverUrl:
                    AddServerCubit.normalizeUrl(cubit.urlController.text)!,
                apiKeyController: cubit.apiKeyController,
                loading: state.loading,
                television: television,
              ),
            if (!cubit.usesNerdVpn ||
                (state.protectedServer &&
                    !state.showAdvanced &&
                    !cubit.usesManualNerdVpnKey))
              gatewaySwitch,
          ]),
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
                ListenableBuilder(
                  listenable: credentials,
                  builder: (context, _) =>
                      cubit.usesNerdVpn && !cubit.usesManualNerdVpnKey
                          ? gatewaySwitch
                          : const SizedBox.shrink(),
                ),
                Text(
                  locals.customHeaders,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
                Text(locals.customHeadersExplanation,
                    style: theme.textTheme.bodySmall),
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
                  onTap: () => showServerBasicAuthDialog(
                    context,
                    (key, value) =>
                        context.read<AddServerCubit>().addHeader(key, value),
                    television: television,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: Text(locals.addHeader),
                  onTap: () => _showHeaderDialog(context),
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
                  delay:
                      AppMotion.fadeDuration(context, animationDuration ~/ 4)),
        FilledButton.tonal(
            onPressed: state.loading || !state.valid ? null : onSubmit,
            child: state.loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: MotionLoadingIndicator(
                        child: CircularProgressIndicator(
                      strokeWidth: 1,
                    )))
                : ListenableBuilder(
                    listenable: credentials,
                    builder: (context, _) => Text(
                        cubit.usesNerdVpn && !cubit.usesManualNerdVpnKey
                            ? locals.nerdVpnSignInAndAdd
                            : locals.testAndAddServer),
                  )),
        ListenableBuilder(
          listenable: credentials,
          builder: (context, _) => cubit.usesManualNerdVpnKey
              ? const SizedBox.shrink()
              : CheckboxListTile(
                  title: Text(
                    locals.alsoTestServerConfig,
                    style: theme.textTheme.bodySmall,
                  ),
                  value: state.advancedTest,
                  onChanged: state.loading || state.publicInstance != null
                      ? null
                      : (value) => cubit.setAdvancedTest(value ?? true),
                ),
        ),
      ],
    );
  }
}
