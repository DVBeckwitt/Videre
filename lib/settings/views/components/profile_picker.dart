import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/models/playback_instance_fallback.dart';
import 'package:clipious/player/models/playback_reliability.dart';
import 'package:clipious/settings/models/db/person_profile.dart';
import 'package:clipious/settings/models/db/server.dart';
import 'package:clipious/subscription_management/services/subscription_account.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'saved_account_setting.dart';

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

  String _backupLabel(Server account, AppLocalizations locals) {
    final label = savedAccountLabel(account, locals);
    if (account.profileId == db.profileId) return label;
    final profile =
        _profiles.where((item) => item.id == account.profileId).firstOrNull;
    return locals.playbackBackupSharedChoice(
        profile?.name ?? locals.profiles, label);
  }

  Widget _reliabilityRow(String title, String outcome,
          {bool backend = false}) =>
      ListTile(
        contentPadding: EdgeInsetsDirectional.only(start: backend ? 16 : 0),
        dense: backend,
        title: Text(title),
        subtitle: Text(outcome),
      );

  Future<void> _showPlaybackReliability() async {
    final locals = AppLocalizations.of(context)!;
    final database = db;
    final owner = database.forProfile(database.profileId);
    List<Server> shared;
    try {
      shared = await PlaybackInstanceFallback.backupChoices(owner);
    } catch (_) {
      shared = const [];
    }
    if (!mounted ||
        !identical(database, db) ||
        db.profileId != owner.profileId) {
      return;
    }
    final accounts = [
      ..._accounts.where((account) => account.profileId == owner.profileId),
      ...shared.where((account) => account.profileId != owner.profileId),
    ];
    String label(PlaybackReliabilityCount counts) => counts.attempts == 0
        ? locals.playbackReliabilityEmpty
        : locals.playbackReliabilityCounts(counts.successes, counts.failures);
    ScrollPosition? scrollPosition;
    void scroll(int direction) {
      final position = scrollPosition;
      if (position == null || !position.hasContentDimensions) return;
      final offset =
          position.pixels + direction * position.viewportDimension / 2;
      position.jumpTo(offset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble());
    }

    await showDialog<void>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => scroll(-1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => scroll(1),
        },
        child: AlertDialog(
          title: Text(locals.playbackReliability),
          scrollable: true,
          content: SizedBox(
            width: 440,
            child: ValueListenableBuilder<int>(
              valueListenable: PlaybackReliability.revision,
              builder: (context, _, __) {
                scrollPosition = Scrollable.maybeOf(context)?.position;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final account in accounts) ...[
                      _reliabilityRow(_backupLabel(account, locals),
                          label(PlaybackReliability.account(owner, account))),
                      for (final (index, backend)
                          in (account.backendSelector?.options ?? []).indexed)
                        _reliabilityRow(
                            backend.label,
                            label(PlaybackReliability.backend(
                                owner, account, index)),
                            backend: true),
                    ],
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      ),
    );
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
                SavedAccountSetting(
                  key: const ValueKey('playback-backup-instance-setting'),
                  title: locals.playbackBackupInstance,
                  defaultLabel: locals.playbackBackupInstanceOff,
                  unavailableLabel: locals.playbackBackupInstanceUnavailable,
                  help: locals.playbackBackupInstanceHelp,
                  automaticChoice: (
                    id: PlaybackInstanceFallback.bestSaved,
                    label: locals.playbackBackupInstanceBest,
                  ),
                  icon: Icons.swap_horiz,
                  revision: PlaybackInstanceFallback.revision,
                  preference: PlaybackInstanceFallback.preference,
                  choices: PlaybackInstanceFallback.backupChoices,
                  choiceId: PlaybackInstanceFallback.choiceId,
                  choiceLabel: _backupLabel,
                  save: PlaybackInstanceFallback.save,
                  enabled: !_busy,
                ),
                ValueListenableBuilder<int>(
                  valueListenable: PlaybackInstanceFallback.revision,
                  builder: (context, _, __) {
                    final owner = db.forProfile(db.profileId);
                    return SwitchListTile(
                      key: const ValueKey('playback-backup-sharing-setting'),
                      secondary: const Icon(Icons.people_outline),
                      title: Text(locals.playbackBackupSharing),
                      subtitle: Text(locals.playbackBackupSharingHelp),
                      value: PlaybackInstanceFallback.sharingEnabled(owner),
                      onChanged: _busy
                          ? null
                          : (enabled) => _run(() =>
                              PlaybackInstanceFallback.saveSharing(
                                  owner, enabled)),
                    );
                  },
                ),
                ValueListenableBuilder<int>(
                  valueListenable: PlaybackInstanceFallback.revision,
                  builder: (context, _, __) {
                    final owner = db.forProfile(db.profileId);
                    return ListTile(
                      leading: const Icon(Icons.replay),
                      title: Text(locals.playbackBackendRetries),
                      subtitle: Text(locals.playbackBackendRetriesHelp),
                      trailing: DropdownButton<int>(
                        key: const ValueKey('playback-backend-retries-setting'),
                        value: PlaybackInstanceFallback.backendRetries(owner),
                        items: [
                          for (var count = 0;
                              count <=
                                  PlaybackInstanceFallback.maxBackendRetries;
                              count++)
                            DropdownMenuItem(
                                value: count, child: Text('$count')),
                        ],
                        onChanged: _busy
                            ? null
                            : (count) {
                                if (count != null) {
                                  _run(() => PlaybackInstanceFallback
                                      .saveBackendRetries(owner, count));
                                }
                              },
                      ),
                    );
                  },
                ),
                ListTile(
                  key: const ValueKey('playback-reliability-setting'),
                  leading: const Icon(Icons.bar_chart),
                  title: Text(locals.playbackReliability),
                  onTap: _busy ? null : _showPlaybackReliability,
                ),
                SavedAccountSetting(
                  key: const ValueKey('subscription-account-setting'),
                  title: locals.subscriptionAccount,
                  defaultLabel: locals.subscriptionAccountDefault,
                  unavailableLabel: locals.subscriptionAccountUnavailable,
                  help: locals.subscriptionAccountHelp,
                  icon: Icons.subscriptions_outlined,
                  revision: SubscriptionAccount.revision,
                  preference: SubscriptionAccount.preference,
                  choices: SubscriptionAccount.choices,
                  save: SubscriptionAccount.save,
                  enabled: !_busy,
                ),
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
