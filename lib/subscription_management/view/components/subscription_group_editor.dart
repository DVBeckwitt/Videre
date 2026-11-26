import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/utils/interfaces/db.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/views/tv/components/tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

import '../../models/subscription_group.dart';
import '../../states/manage_subscriptions.dart';

const _selectShortcut = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
};

Future<void> showSubscriptionGroupEditor(
  BuildContext context, {
  required IDbClient database,
  SubscriptionGroup? group,
}) =>
    showDialog<void>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (_) => Shortcuts(
        shortcuts: _selectShortcut,
        child: BlocProvider(
          create: (_) =>
              ManageSubscriptionCubit(const ManageSubscriptionsState()),
          child: _SubscriptionGroupEditor(database: database, group: group),
        ),
      ),
    );

class _SubscriptionGroupEditor extends StatefulWidget {
  final IDbClient database;
  final SubscriptionGroup? group;

  const _SubscriptionGroupEditor({required this.database, this.group});

  @override
  State<_SubscriptionGroupEditor> createState() =>
      _SubscriptionGroupEditorState();
}

class _SubscriptionGroupEditorState extends State<_SubscriptionGroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name)
    ..addListener(_nameChanged);
  late final _id = widget.group?.id ?? const Uuid().v4();
  late final _selected = {...?widget.group?.channelIds};
  bool _saving = false;
  bool _hasError = false;

  void _nameChanged() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _update(Future<void> Function() write) async {
    final route = ModalRoute.of(context);
    if (_saving || route == null || !route.isCurrent) return;
    setState(() {
      _saving = true;
      _hasError = false;
    });
    try {
      await write();
      if (!mounted) return;
      if (route.isCurrent) {
        Navigator.of(context).pop();
      } else {
        setState(() => _saving = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _hasError = true;
        });
      }
    }
  }

  Future<void> _save() => _update(
        () => widget.database.saveSubscriptionGroup(
          SubscriptionGroup(
            id: _id,
            name: _name.text.trim(),
            channelIds: _selected,
          ),
        ),
      );

  Future<void> _delete(SubscriptionGroup group) async {
    final locals = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => Shortcuts(
        shortcuts: _selectShortcut,
        child: AlertDialog(
          scrollable: true,
          title: Text(locals.subscriptionGroupDelete),
          content: Text(locals.subscriptionGroupDeleteConfirmation(group.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(locals.cancel),
            ),
            FilledButton(
              key: const ValueKey('confirm-delete-subscription-group'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(locals.subscriptionGroupDelete),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      await _update(() => widget.database.deleteSubscriptionGroup(group.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final group = widget.group;
    final nameInput = Text(locals.subscriptionGroupName);
    final subscriptions = context.watch<ManageSubscriptionCubit>();
    final state = subscriptions.state;
    final channels = <String, String>{
      for (final sub in state.offlineSubs)
        if (sub.channelId.isNotEmpty) sub.channelId: sub.channelName,
      for (final sub in state.subs)
        if (sub.authorId.isNotEmpty) sub.authorId: sub.author,
    };
    final available = channels.keys.toList()
      ..sort((a, b) =>
          channels[a]!.toLowerCase().compareTo(channels[b]!.toLowerCase()));
    final unavailable = state.loading
        ? const <String>[]
        : group?.channelIds.where((id) => !channels.containsKey(id)) ??
            const <String>[];
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(group == null
            ? locals.subscriptionGroupNew
            : locals.subscriptionGroupEdit),
        content: SizedBox(
          width: 480,
          height: 420,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  primary: false,
                  children: [
                    if (isTv)
                      ExcludeFocus(
                        excluding: _saving,
                        child: TvTextField(
                          controller: _name,
                          decoration: InputDecoration(label: nameInput),
                        ),
                      )
                    else
                      TextField(
                        controller: _name,
                        enabled: !_saving,
                        decoration: InputDecoration(label: nameInput),
                        textCapitalization: TextCapitalization.words,
                      ),
                    if (_saving || state.loading)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: MotionLoadingIndicator(
                          child: LinearProgressIndicator(),
                        ),
                      ),
                    if (state.hasError)
                      ListTile(
                        title: Text(locals.itemlistErrorGeneric),
                        trailing: TextButton(
                          onPressed: _saving ? null : subscriptions.refreshSubs,
                          child: Text(locals.retry),
                        ),
                      ),
                    if (!state.loading &&
                        !state.hasError &&
                        available.isEmpty &&
                        unavailable.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(locals.noChannels),
                      ),
                    for (final id in [...available, ...unavailable])
                      CheckboxListTile(
                        key: ValueKey('subscription-group-channel-$id'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(channels[id]?.isNotEmpty == true
                            ? channels[id]!
                            : id),
                        subtitle: channels.containsKey(id)
                            ? null
                            : Text(locals.subscriptionGroupUnavailableChannel),
                        value: _selected.contains(id),
                        onChanged: _saving
                            ? null
                            : (selected) => setState(() {
                                  if (selected == true) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                }),
                      ),
                  ],
                ),
              ),
              if (_hasError)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      locals.subscriptionGroupUpdateFailed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          if (group != null)
            TextButton(
              onPressed: _saving ? null : () => _delete(group),
              child: Text(locals.subscriptionGroupDelete),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
          FilledButton(
            onPressed: _saving || _name.text.trim().isEmpty ? null : _save,
            child: Text(locals.save),
          ),
        ],
      ),
    );
  }
}
