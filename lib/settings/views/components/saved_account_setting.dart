import 'dart:async' show FutureOr;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/interfaces/db.dart';
import '../../../utils/motion.dart';
import '../../models/db/server.dart';

String savedAccountLabel(Server account, AppLocalizations locals) {
  final uri = Uri.tryParse(account.url);
  final origin = uri != null &&
          uri.host.isNotEmpty &&
          (uri.scheme == 'http' || uri.scheme == 'https')
      ? uri.origin
      : locals.invidiousAccount;
  return account.name.trim().isEmpty ? origin : '${account.name} · $origin';
}

class SavedAccountSetting extends StatelessWidget {
  final String title;
  final String defaultLabel;
  final String unavailableLabel;
  final String? help;
  final ({String id, String label})? automaticChoice;
  final IconData icon;
  final bool enabled;
  final ValueListenable<int> revision;
  final FutureOr<String?> Function(IDbClient owner) preference;
  final Future<List<Server>> Function(IDbClient owner) choices;
  final Future<void> Function(IDbClient owner, String? accountId) save;
  final String Function(IDbClient owner, Server account)? choiceId;
  final String Function(Server account, AppLocalizations locals)? choiceLabel;

  const SavedAccountSetting({
    super.key,
    required this.title,
    required this.defaultLabel,
    required this.unavailableLabel,
    this.help,
    this.automaticChoice,
    required this.icon,
    this.enabled = true,
    required this.revision,
    required this.preference,
    required this.choices,
    required this.save,
    this.choiceId,
    this.choiceLabel,
  });

  Future<(String?, List<Server>)> _read(IDbClient owner) async =>
      (await preference(owner), await choices(owner));

  String _id(IDbClient owner, Server account) =>
      choiceId?.call(owner, account) ?? account.accountId;

  String _label(Server account, AppLocalizations locals) =>
      choiceLabel?.call(account, locals) ?? savedAccountLabel(account, locals);

  ({String id, String label})? _automatic(
          IDbClient owner, List<Server> accounts) =>
      accounts.any((account) => account.profileId == owner.profileId)
          ? automaticChoice
          : null;

  Future<void> _choose(BuildContext context) async {
    final locals = AppLocalizations.of(context)!;
    final app = context.read<AppCubit?>();
    final sessionRevision = app?.state.sessionRevision;
    final database = db;
    final owner = database.forProfile(database.profileId);
    bool current() =>
        identical(db, database) &&
        database.profileId == owner.profileId &&
        (app == null ||
            (!app.isClosed &&
                app.state.sessionRevision == sessionRevision &&
                !app.state.globalLoading &&
                !app.state.sessionRecoveryRequired));

    try {
      final (selected, accounts) = await _read(owner);
      if (!context.mounted || !current()) return;
      final initial = selected ?? '';
      final automatic = _automatic(owner, accounts);
      final choice = await showDialog<String>(
        context: context,
        animationStyle: AppMotion.dialogStyle(context),
        useRootNavigator: false,
        builder: (context) => SimpleDialog(
          title: Text(title),
          children: [
            if (help case final description?)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(description),
              ),
            for (final (id, label) in [
              ('', defaultLabel),
              if (automatic != null) (automatic.id, automatic.label),
              for (final account in accounts)
                (_id(owner, account), _label(account, locals)),
            ])
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(id),
                child: Row(children: [
                  Expanded(child: Text(label)),
                  if (id == initial) const Icon(Icons.check),
                ]),
              ),
          ],
        ),
      );
      if (!context.mounted ||
          !current() ||
          choice == null ||
          choice == initial) {
        return;
      }
      await save(owner, choice.isEmpty ? null : choice);
    } catch (_) {
      if (!context.mounted || !current()) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(locals.itemlistErrorGeneric)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.select((AppCubit? app) => app?.state);
    final locals = AppLocalizations.of(context)!;
    return ValueListenableBuilder<int>(
      valueListenable: revision,
      builder: (context, _, __) {
        final owner = db.forProfile(db.profileId);
        return FutureBuilder<(String?, List<Server>)>(
          key: ValueKey(owner.profileId),
          future: _read(owner),
          builder: (context, snapshot) {
            final (preference, accounts) =
                snapshot.data ?? (null, const <Server>[]);
            final account = accounts
                .where((account) => _id(owner, account) == preference)
                .firstOrNull;
            final automatic = _automatic(owner, accounts);
            final label = switch (preference) {
              _ when snapshot.hasError => unavailableLabel,
              null => defaultLabel,
              _ when automatic != null && preference == automatic.id =>
                automatic.label,
              _ when account != null => _label(account, locals),
              _ => unavailableLabel,
            };
            return ListTile(
              leading: Icon(icon),
              title: Text(title),
              subtitle: Text(label),
              onTap: !enabled ||
                      session?.globalLoading == true ||
                      session?.sessionRecoveryRequired == true
                  ? null
                  : () => _choose(context),
            );
          },
        );
      },
    );
  }
}
