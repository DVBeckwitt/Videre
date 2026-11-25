import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_online_recents.dart';
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class MusicOnlineRecentsButton extends StatelessWidget {
  const MusicOnlineRecentsButton({super.key, required this.onUse});

  final ValueChanged<String> onUse;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>();
    final session = app.state;
    final database = db;
    final locals = AppLocalizations.of(context)!;

    bool current() {
      if (!context.mounted || app.isClosed || !identical(db, database)) {
        return false;
      }
      final active = app.state;
      return !active.globalLoading &&
          !active.sessionRecoveryRequired &&
          active.profileId == session.profileId &&
          active.sessionRevision == session.sessionRevision &&
          database.profileId == session.profileId;
    }

    if (!current()) return const SizedBox.shrink();
    final recents = MusicOnlineRecents.forProfile(database, session.profileId);
    return ListenableBuilder(
      listenable: recents,
      builder: (context, _) {
        if (!current() || !recents.enabled) return const SizedBox.shrink();
        return IconButton(
          tooltip: locals.musicSearchRecentQueries,
          icon: const Icon(Icons.history),
          onPressed: () async {
            if (!current() || !recents.enabled) return;
            final query = await showDialog<String>(
              context: context,
              useRootNavigator: false,
              animationStyle: AppMotion.dialogStyle(context),
              builder: (context) => BlocListener<AppCubit, AppState>(
                bloc: app,
                listener: (context, _) {
                  if (current()) return;
                  final route = ModalRoute.of(context);
                  if (route != null && route.isActive) {
                    route.navigator?.removeRoute(route);
                  }
                },
                child: _MusicOnlineRecentsDialog(
                    recents: recents, isCurrent: current),
              ),
            );
            if (query != null && current() && recents.enabled) onUse(query);
          },
        );
      },
    );
  }
}

class _MusicOnlineRecentsDialog extends StatefulWidget {
  const _MusicOnlineRecentsDialog(
      {required this.recents, required this.isCurrent});

  final MusicOnlineRecents recents;
  final bool Function() isCurrent;

  @override
  State<_MusicOnlineRecentsDialog> createState() =>
      _MusicOnlineRecentsDialogState();
}

class _MusicOnlineRecentsDialogState extends State<_MusicOnlineRecentsDialog> {
  String? _editing;
  String _draft = '';
  bool _saveFailed = false;

  Future<bool> _update(Future<void> Function() operation) async {
    if (!widget.isCurrent()) return false;
    try {
      await operation();
      return true;
    } catch (_) {
      if (mounted && widget.isCurrent()) setState(() => _saveFailed = true);
      return false;
    }
  }

  void _edit(String query) {
    setState(() {
      _editing = query;
      _draft = query;
      _saveFailed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final material = MaterialLocalizations.of(context);
    final recents = widget.recents;
    return ListenableBuilder(
      listenable: recents,
      builder: (context, _) {
        final queries = widget.isCurrent() ? recents.queries : const <String>[];
        final editing = _editing;
        if (editing != null && queries.contains(editing)) {
          return AlertDialog(
            scrollable: true,
            title: Text(locals.musicSearchRecentEdit),
            content: TextFormField(
              autofocus: true,
              initialValue: editing,
              maxLength: MusicOnlineRecents.maxQueryLength,
              decoration: InputDecoration(
                  labelText: locals.search,
                  errorText: _saveFailed ? locals.error : null),
              onChanged: (text) => setState(() {
                _draft = text;
                _saveFailed = false;
              }),
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() {
                  _editing = null;
                  _saveFailed = false;
                }),
                child: Text(locals.cancel),
              ),
              TextButton(
                onPressed: MusicOnlineRecents.canSaveQuery(_draft)
                    ? () async {
                        final saved = await _update(() => recents.rename(
                            editing, _draft,
                            isCurrent: widget.isCurrent));
                        if (mounted && saved) setState(() => _editing = null);
                      }
                    : null,
                child: Text(locals.save),
              ),
            ],
          );
        }
        return AlertDialog(
          scrollable: true,
          title: Text(locals.musicSearchRecentQueries),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_saveFailed) Text(locals.error),
                if (queries.isEmpty) Text(locals.musicSearchRecentEmpty),
                for (final query in queries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(query),
                    onTap: () {
                      if (widget.isCurrent() && recents.enabled) {
                        Navigator.of(context).pop(query);
                      }
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: locals.musicSearchRecentEdit,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _edit(query),
                        ),
                        IconButton(
                          tooltip: locals.musicSearchRecentRemove,
                          icon: const Icon(Icons.close),
                          onPressed: () async {
                            final saved = await _update(() => recents
                                .remove(query, isCurrent: widget.isCurrent));
                            if (mounted && saved && _saveFailed) {
                              setState(() => _saveFailed = false);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            if (queries.isNotEmpty)
              TextButton(
                onPressed: () async {
                  final saved = await _update(
                      () => recents.clear(isCurrent: widget.isCurrent));
                  if (mounted && saved && _saveFailed) {
                    setState(() => _saveFailed = false);
                  }
                },
                child: Text(locals.clearSearchHistory),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(material.closeButtonLabel),
            ),
          ],
        );
      },
    );
  }
}
