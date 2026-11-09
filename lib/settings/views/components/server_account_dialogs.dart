import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../network/nerdvpn_access.dart';
import '../../../utils.dart';
import '../../../utils/motion.dart';
import '../../../utils/string.dart';
import '../../../utils/views/tv/components/tv_button.dart';
import '../../../utils/views/tv/components/tv_text_field.dart';
import '../../services/gateway_auth.dart';
import '../../states/server_settings.dart';

Future<void> showServerKeyValueDialog(
  BuildContext context, {
  required String field1Title,
  required String field2Title,
  bool field1Secret = false,
  bool field2Secret = false,
  List<String>? field1AutofillHints,
  List<String>? field2AutofillHints,
  required String okText,
  required FutureOr<void> Function(String, String) onOk,
  bool television = false,
}) {
  final locals = AppLocalizations.of(context)!;
  final field1Controller = TextEditingController();
  final field2Controller = TextEditingController();

  Widget field(TextEditingController controller, String title, bool secret,
      List<String>? hints) {
    final decoration = InputDecoration(label: Text(title));
    return television
        ? TvTextField(
            controller: controller,
            autocorrect: false,
            autofillHints: hints,
            obscureText: secret,
            decoration: decoration)
        : TextField(
            controller: controller,
            autocorrect: false,
            autofillHints: hints,
            obscureText: secret,
            decoration: decoration);
  }

  Widget button(String label, VoidCallback onPressed) => television
      ? TvButton(
          unfocusedColor: Colors.transparent,
          onPressed: (_) => onPressed(),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(label),
          ))
      : TextButton(onPressed: onPressed, child: Text(label));

  return showDialog<void>(
    animationStyle: AppMotion.dialogStyle(context),
    context: context,
    useRootNavigator: false,
    builder: (context) {
      final actions = [
        button(locals.cancel, () => Navigator.of(context).pop()),
        button(
            okText, () => onOk(field1Controller.text, field2Controller.text)),
      ];
      return AlertDialog(
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          field(
              field1Controller, field1Title, field1Secret, field1AutofillHints),
          field(
              field2Controller, field2Title, field2Secret, field2AutofillHints),
        ]),
        actions: television
            ? [Row(mainAxisAlignment: MainAxisAlignment.end, children: actions)]
            : actions,
      );
    },
  );
}

Future<void> showServerBasicAuthDialog(
    BuildContext context, Future<void> Function(String, String) saveHeader,
    {bool television = false}) {
  final locals = AppLocalizations.of(context)!;
  return showServerKeyValueDialog(context,
      television: television,
      field1Title: locals.username,
      field2Title: locals.password,
      field1AutofillHints: const [AutofillHints.username, AutofillHints.email],
      field2AutofillHints: const [AutofillHints.password],
      field2Secret: true,
      okText: locals.add, onOk: (username, password) async {
    final credentials = encodeBase64('$username:$password');
    await saveHeader('Authorization', 'Basic $credentials');
    if (context.mounted) Navigator.of(context).pop();
  });
}

void showServerHeaderDialog(BuildContext context, {bool television = false}) {
  final locals = AppLocalizations.of(context)!;
  showServerKeyValueDialog(context,
      television: television,
      field1Title: locals.name,
      field2Title: locals.value,
      okText: locals.add, onOk: (key, value) async {
    final cubit = context.read<ServerSettingsCubit>();
    if (NerdVpnAccess.supports(cubit.state.server) &&
        NerdVpnAccess.isKeyHeader(key) &&
        !NerdVpnAccess.isValidKey(value)) {
      if (television) {
        showTvAlertdialog(
            context, locals.error, [Text(locals.nerdVpnKeyInvalid)]);
      } else {
        await showAlertDialog(
            context, locals.error, [Text(locals.nerdVpnKeyInvalid)]);
      }
      return;
    }
    await runServerAccountAction(context, () async {
      await cubit.addHeader(key, value);
      if (context.mounted) Navigator.of(context).pop();
    }, television: television);
  });
}

Future<void> runServerAccountAction(
    BuildContext context, Future<void> Function() action,
    {bool television = false}) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    final locals = AppLocalizations.of(context)!;
    final approvalPending =
        error is NerdVpnAccessRequired && error.state == 'waiting';
    final title =
        approvalPending ? locals.nerdVpnApprovalPending : locals.error;
    final message = Text(approvalPending
        ? locals.nerdVpnAccessPending
        : error is GatewayUnsupported ||
                error is GatewaySignInFailed ||
                error is NerdVpnAccessRequired
            ? error.toString()
            : locals.accountActionFailed);
    if (television) {
      showTvAlertdialog(context, title, [message]);
    } else {
      await showAlertDialog(context, title, [message]);
    }
  }
}
