import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../network/media_companion.dart';
import '../../../utils/motion.dart';
import '../../../utils/views/components/external_link.dart';
import '../../../utils/views/tv/components/tv_text_field.dart';
import '../../models/db/server.dart';
import '../../states/server_settings.dart';

Future<Set<String>?> chooseSetupMediaCompanions(
    BuildContext context, Server account, Set<String> candidates) async {
  final instance = mediaCompanionInstanceAddress(account);
  if (instance == null) return {};
  final frontendOrigin = Uri.parse(instance).origin;
  final origins = candidates
      .where((value) =>
          value != frontendOrigin && parseMediaCompanionOrigin(value) == value)
      .toList()
    ..sort();
  if (origins.isEmpty || origins.length > maxMediaCompanionOrigins) return {};
  return showDialog<Set<String>>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => _remoteSelect(_MediaCompanionChoice(
        instance: instance,
        origins: origins,
        setup: true,
        available: maxMediaCompanionOrigins)),
  );
}

Widget _remoteSelect(Widget child) => Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: child,
    );

Future<void> findMediaCompanionHosts(
    BuildContext context, Server account) async {
  final settings = context.read<ServerSettingsCubit>();
  final activeAccount = settings.app.state.server?.accountId;
  final instance = mediaCompanionInstanceAddress(account);
  if (instance == null) return;
  final locals = AppLocalizations.of(context)!;
  Future<Set<String>>? check;
  final result = await showDialog<Set<String>>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (dialogContext) {
        final route = ModalRoute.of(dialogContext)!;
        check ??= settings.findMediaCompanions(account,
            isCurrent: () => dialogContext.mounted && route.isCurrent);
        return _remoteSelect(FutureBuilder<Set<String>>(
          future: check,
          builder: (context, snapshot) {
            final waiting = snapshot.connectionState != ConnectionState.done;
            final existing =
                trustedMediaCompanionOrigins(settings.state.server);
            final candidates = (snapshot.data ?? const <String>{})
                .difference(existing)
                .toList()
              ..sort();
            final available = maxMediaCompanionOrigins - existing.length;
            if (candidates.isNotEmpty && available > 0) {
              return _MediaCompanionChoice(
                  instance: instance,
                  origins: candidates,
                  setup: false,
                  available: available);
            }
            return AlertDialog(
              scrollable: true,
              title: Text(locals.mediaCompanionFind),
              content: Text(waiting
                  ? locals.mediaCompanionChecking
                  : snapshot.hasError
                      ? locals.mediaCompanionCheckFailed
                      : locals.mediaCompanionNoNewHosts),
              actions: [
                TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(waiting ? locals.cancel : locals.ok),
                )
              ],
            );
          },
        ));
      });
  if (result == null ||
      result.isEmpty ||
      !context.mounted ||
      ModalRoute.of(context)?.isCurrent != true ||
      settings.app.state.server?.accountId != activeAccount) {
    return;
  }
  await settings.setMediaCompanionOrigins(account, result, enabled: true);
}

Future<void> showMediaCompanionHelp(BuildContext context) {
  final locals = AppLocalizations.of(context)!;
  return showDialog<void>(
      context: context,
      useRootNavigator: false,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => _remoteSelect(AlertDialog(
            scrollable: true,
            title: Text(locals.mediaCompanionHelpTitle),
            content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(locals.mediaCompanionExplain),
                  const SizedBox(height: 12),
                  Text(locals.mediaCompanionWhere),
                  const SizedBox(height: 12),
                  Text(locals.mediaCompanionExample),
                  for (final (label, address) in [
                    (
                      locals.mediaCompanionUserGuide,
                      'https://github.com/DVBeckwitt/Videre/blob/master/README.md#media-companion-hosts'
                    ),
                    (
                      locals.mediaCompanionOperatorGuide,
                      'https://docs.invidious.io/installation/#advanced-improve-performance'
                    ),
                  ])
                    TextButton(
                      onPressed: () => openExternalLink(
                          context, Uri.parse(address),
                          title: label),
                      child: Text(label),
                    )
                ]),
            actions: [
              TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(locals.ok)),
            ],
          )));
}

class _MediaCompanionChoice extends StatefulWidget {
  final String instance;
  final List<String> origins;
  final bool setup;
  final int available;
  const _MediaCompanionChoice(
      {required this.instance,
      required this.origins,
      required this.setup,
      required this.available});

  @override
  State<_MediaCompanionChoice> createState() => _MediaCompanionChoiceState();
}

class _MediaCompanionChoiceState extends State<_MediaCompanionChoice> {
  final selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final origins = widget.origins;
    final single = origins.length == 1;
    return AlertDialog(
      scrollable: true,
      title: Text(locals.mediaCompanionSetupTitle(origins.length)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(locals.mediaCompanionSetupHelp(
                widget.instance, origins.length)),
            const SizedBox(height: 12),
            if (single)
              Text(origins.single,
                  textDirection: TextDirection.ltr,
                  style: Theme.of(context).textTheme.titleMedium)
            else
              for (final origin in origins)
                CheckboxListTile(
                  title: Text(origin, textDirection: TextDirection.ltr),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  value: selected.contains(origin),
                  onChanged: !selected.contains(origin) &&
                          selected.length >= widget.available
                      ? null
                      : (checked) => setState(() {
                            if (checked == true) {
                              selected.add(origin);
                            } else {
                              selected.remove(origin);
                            }
                          }),
                ),
            const SizedBox(height: 12),
            Text(locals.mediaCompanionSetupPrivacy(widget.instance)),
            const SizedBox(height: 8),
            Text(widget.setup
                ? locals.mediaCompanionSetupScope
                : locals.mediaCompanionSettingsScope(widget.instance)),
          ],
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(<String>{}),
          child: Text(
              widget.setup ? locals.mediaCompanionSetupSkip : locals.cancel),
        ),
        FilledButton(
          onPressed: single || selected.isNotEmpty
              ? () => Navigator.of(context)
                  .pop(single ? {origins.single} : selected.toSet())
              : null,
          child: Text(
            single
                ? locals.mediaCompanionSetupAllow(origins.single)
                : locals.mediaCompanionSetupAllowSelected,
            // The complete origin remains visible in the scrollable body.
            maxLines: single ? 2 : null,
            overflow: single ? TextOverflow.ellipsis : null,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

Future<void> showMediaCompanionDialog(BuildContext context, Server account,
    {bool television = false}) {
  final instance = mediaCompanionInstanceAddress(account);
  if (instance == null) return Future.value();
  final settings = context.read<ServerSettingsCubit>();
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => _MediaCompanionDialog(
      account: account,
      instance: instance,
      television: television,
      onAllow: (origin) =>
          settings.setMediaCompanionOrigin(account, origin, enabled: true),
    ),
  );
}

class _MediaCompanionDialog extends StatefulWidget {
  final Server account;
  final String instance;
  final bool television;
  final Future<void> Function(String origin) onAllow;

  const _MediaCompanionDialog(
      {required this.account,
      required this.instance,
      required this.television,
      required this.onAllow});

  @override
  State<_MediaCompanionDialog> createState() => _MediaCompanionDialogState();
}

class _MediaCompanionDialogState extends State<_MediaCompanionDialog> {
  final _address = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _allow() async {
    if (_saving) return;
    final locals = AppLocalizations.of(context)!;
    final origin = parseMediaCompanionOrigin(_address.text.trim());
    if (origin == null || origin == Uri.parse(widget.account.url).origin) {
      setState(() => _error = locals.mediaCompanionInvalid);
      return;
    }
    if (trustedMediaCompanionOrigins(widget.account).contains(origin)) {
      setState(() => _error = locals.mediaCompanionAlreadyAllowed);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onAllow(origin);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      } else if (mounted) {
        setState(() => _saving = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = locals.accountActionFailed;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final decoration = InputDecoration(
        label: Text(locals.mediaCompanionAddress),
        hintText: 'https://media.example.org');
    return Shortcuts(
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      child: PopScope(
        canPop: !_saving,
        child: AlertDialog(
          scrollable: true,
          title: Text(locals.mediaCompanionAdd),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.mediaCompanionHelp(widget.instance)),
            TextButton(
              onPressed: _saving ? null : () => showMediaCompanionHelp(context),
              child: Text(locals.mediaCompanionHelpTitle),
            ),
            const SizedBox(height: 12),
            if (widget.television)
              ExcludeFocus(
                excluding: _saving,
                child: TvTextField(
                  autofocus: true,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  controller: _address,
                  decoration: decoration,
                ),
              )
            else
              TextField(
                autofocus: true,
                enabled: !_saving,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                controller: _address,
                decoration: decoration,
              ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
          actions: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: Text(locals.cancel),
            ),
            FilledButton(
              onPressed: _saving ? null : _allow,
              child: Text(locals.mediaCompanionAdd),
            ),
          ],
        ),
      ),
    );
  }
}
