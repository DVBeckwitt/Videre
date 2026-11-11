import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/settings/models/db/person_profile.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

Future<void> showProfilePicker(BuildContext context) {
  final app = context.read<AppCubit>();
  return showDialog<void>(
    context: context,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) =>
        BlocProvider.value(value: app, child: const ProfilePicker()),
  );
}

Future<String?> showProfileNameDialog(BuildContext context,
        {required String title,
        required String label,
        String initialName = ''}) =>
    showDialog<String>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (_) => Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: _ProfileNameDialog(
            title: title, label: label, initialName: initialName),
      ),
    );

class _ProfileNameDialog extends StatefulWidget {
  final String title;
  final String label;
  final String initialName;
  const _ProfileNameDialog(
      {required this.title, required this.label, required this.initialName});

  @override
  State<_ProfileNameDialog> createState() => _ProfileNameDialogState();
}

class _ProfileNameDialogState extends State<_ProfileNameDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return AlertDialog(
      scrollable: true,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
      title: Text(widget.title),
      content: TextField(
          key: const ValueKey('profile-name-input'),
          controller: _controller,
          autofocus: true,
          maxLength: 80,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: widget.label),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit()),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel)),
        FilledButton(
            onPressed: _controller.text.trim().isEmpty ? null : _submit,
            child: Text(locals.save)),
      ],
    );
  }
}

class ProfilePicker extends StatefulWidget {
  const ProfilePicker({super.key});

  @override
  State<ProfilePicker> createState() => _ProfilePickerState();
}

class _ProfilePickerState extends State<ProfilePicker> {
  List<PersonProfile> _profiles = [];
  List<Server> _accounts = [];
  bool _busy = true;
  bool _failed = false;
  BuildContext? _pendingFocusRow;

  void _revealFocusedRow(BuildContext row, bool focused) {
    if (!focused) return;
    _pendingFocusRow = row;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_pendingFocusRow, row)) return;
      _pendingFocusRow = null;
      if (!mounted || !row.mounted) return;
      final primary = FocusManager.instance.primaryFocus?.context;
      var belongsToRow = identical(primary, row);
      primary?.visitAncestorElements((element) {
        if (identical(element, row)) belongsToRow = true;
        return !belongsToRow;
      });
      if (!belongsToRow) return;
      // Reveal the person's name with its actions, including initial autofocus.
      // Revealing only a focused icon can leave the deletion target clipped.
      Scrollable.ensureVisible(row,
          alignment: 0.5,
          duration: AppMotion.duration(row, const Duration(milliseconds: 150)));
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles = await db.getProfiles();
      profiles.sort((first, second) {
        if (first.id == second.id) return 0;
        if (first.id == PersonProfile.defaultId) return -1;
        if (second.id == PersonProfile.defaultId) return 1;
        return first.name.toLowerCase().compareTo(second.name.toLowerCase());
      });
      final accounts = await db.getServers();
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _accounts = accounts;
          _busy = false;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action,
      {bool closeOnSuccess = false}) async {
    if (_busy) return;
    final route = ModalRoute.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failureMessage = AppLocalizations.of(context)!.profileActionFailed;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
      if (!mounted) return;
      if (closeOnSuccess) {
        // Resetting the app's routes can leave this dialog mounted while its
        // exit animation runs. Do not pop the newly selected profile's route.
        if (route?.isCurrent ?? false) Navigator.of(context).pop();
      } else {
        await _load();
      }
    } catch (_) {
      if (mounted && (route?.isCurrent ?? false)) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      } else if (messenger?.mounted ?? false) {
        messenger!.showSnackBar(SnackBar(content: Text(failureMessage)));
      }
    }
  }

  Future<void> _add() async {
    final locals = AppLocalizations.of(context)!;
    final name = await showProfileNameDialog(context,
        title: locals.addProfile, label: locals.profileName);
    if (name == null || !mounted) return;
    final app = context.read<AppCubit>();
    await _run(() async {
      final profile = await db.createProfile(name);
      await app.switchProfile(profile.id);
    }, closeOnSuccess: true);
  }

  Future<void> _rename(PersonProfile profile) async {
    final locals = AppLocalizations.of(context)!;
    final name = await showProfileNameDialog(context,
        title: locals.renameProfile,
        label: locals.profileName,
        initialName: profile.name);
    if (name == null || !mounted) return;
    await _run(() => db.renameProfile(profile.id, name));
  }

  Future<void> _delete(PersonProfile profile) async {
    if (_busy || _profiles.length < 2) return;
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: AlertDialog(
          scrollable: true,
          title: Text(locals.deleteProfile),
          content: Text(locals.deleteProfileConfirmation(profile.name)),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(locals.cancel)),
            FilledButton(
                key: const ValueKey('confirm-delete-profile'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(locals.deleteProfile)),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final app = context.read<AppCubit>();
    await _run(() => app.deleteProfile(profile.id));
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final app = context.read<AppCubit>();
    return PopScope(
      canPop: !_busy,
      child: Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        child: AlertDialog(
          title: Text(locals.profiles),
          scrollable: true,
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
          content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(locals.profileLibraryHelp),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child:
                      MotionLoadingIndicator(child: LinearProgressIndicator()),
                ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(locals.profileActionFailed,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              for (final profile in _profiles)
                Builder(
                    key: ValueKey('profile-row-${profile.id}'),
                    builder: (rowContext) => ListTile(
                          key: ValueKey('profile-${profile.id}'),
                          autofocus: profile.id == db.profileId,
                          onFocusChange: (focused) =>
                              _revealFocusedRow(rowContext, focused),
                          leading: Icon(profile.id == db.profileId
                              ? Icons.check_circle
                              : Icons.person_outline),
                          title: Text(profile.name),
                          enabled: !_busy,
                          onTap: () => _run(() => app.switchProfile(profile.id),
                              closeOnSuccess: true),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            Focus(
                              canRequestFocus: false,
                              skipTraversal: true,
                              onFocusChange: (focused) =>
                                  _revealFocusedRow(rowContext, focused),
                              child: IconButton(
                                  tooltip: locals.renameProfile,
                                  onPressed:
                                      _busy ? null : () => _rename(profile),
                                  icon: const Icon(Icons.edit_outlined)),
                            ),
                            Focus(
                              canRequestFocus: false,
                              skipTraversal: true,
                              onFocusChange: (focused) =>
                                  _revealFocusedRow(rowContext, focused),
                              child: IconButton(
                                  key: ValueKey('delete-profile-${profile.id}'),
                                  tooltip: locals.deleteProfile,
                                  onPressed: _busy || _profiles.length < 2
                                      ? null
                                      : () => _delete(profile),
                                  icon:
                                      const Icon(Icons.person_remove_outlined)),
                            ),
                          ]),
                        )),
              if (_profiles.length == 1)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(locals.lastProfileRequired),
                ),
              if (_accounts.isNotEmpty) ...[
                const Divider(),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text(locals.yourServers)),
                for (final account in _accounts)
                  ListTile(
                    key: ValueKey('account-${account.accountId}'),
                    leading: Icon(account.inUse
                        ? Icons.check_circle
                        : Icons.dns_outlined),
                    title:
                        Text(account.name.isEmpty ? account.url : account.name),
                    subtitle: account.name.isEmpty ? null : Text(account.url),
                    enabled: !_busy,
                    onTap: () => _run(() async {
                      await app.switchServer(account);
                    }, closeOnSuccess: true),
                  ),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: Text(locals.cancel)),
            FilledButton.icon(
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.person_add_outlined),
                label: Text(locals.addProfile)),
          ],
        ),
      ),
    );
  }
}
