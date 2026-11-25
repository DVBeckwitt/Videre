import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../utils/interfaces/db.dart';
import '../../../utils/motion.dart';
import '../../services/music_starter_artists.dart';

class MusicStarterArtistsSection extends StatelessWidget {
  const MusicStarterArtistsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppCubit>().state;
    final database = db;
    if (session.globalLoading ||
        session.sessionRecoveryRequired ||
        database.profileId != session.profileId) {
      return const SizedBox.shrink();
    }
    return _ProfileStarterArtists(
      key: ValueKey((database, session.profileId, session.sessionRevision)),
      database: database,
      session: session,
    );
  }
}

class _ProfileStarterArtists extends StatefulWidget {
  final IDbClient database;
  final AppState session;

  const _ProfileStarterArtists({
    super.key,
    required this.database,
    required this.session,
  });

  @override
  State<_ProfileStarterArtists> createState() => _ProfileStarterArtistsState();
}

class _ProfileStarterArtistsState extends State<_ProfileStarterArtists> {
  late final _artists =
      MusicStarterArtists(widget.database, widget.session.profileId);
  bool _editing = false;

  bool get _current {
    if (!mounted || !identical(widget.database, db)) return false;
    final session = context.read<AppCubit>().state;
    return !session.globalLoading &&
        !session.sessionRecoveryRequired &&
        session.profileId == widget.session.profileId &&
        session.profileId == db.profileId &&
        session.sessionRevision == widget.session.sessionRevision;
  }

  Future<void> _edit() async {
    if (_editing || !_current) return;
    setState(() => _editing = true);
    try {
      final picks = await showDialog<List<String>>(
        context: context,
        useRootNavigator: false,
        animationStyle: AppMotion.dialogStyle(context),
        builder: (_) => _StarterArtistDialog(initial: _artists.picks),
      );
      if (_current && picks != null) await _artists.save(picks);
    } catch (_) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.recommendationError),
        ));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  void _search(String artist) {
    if (_current &&
        context.read<AppCubit>().state.server != null &&
        (_artists.picks?.contains(artist) ?? false)) {
      context.router.push(MusicRoute(initialQuery: artist));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _artists.changes,
      builder: (context, _) {
        final picks = _artists.picks;
        final canSearch = widget.session.server != null;
        return Column(
          key: const ValueKey('music-starter-artists'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (picks == null) ...[
              Text(locals.musicStarterArtists,
                  style: Theme.of(context).textTheme.titleLarge),
              Text(locals.musicStarterArtistsHint),
              FilledButton.tonal(
                key: const ValueKey('music-starter-artists-edit'),
                onPressed: _editing ? null : _edit,
                child: Text(locals.musicStarterArtistsChoose),
              ),
            ] else ...[
              if (picks.isNotEmpty) ...[
                Text(locals.musicStarterArtists,
                    style: Theme.of(context).textTheme.titleLarge),
                if (canSearch) Text(locals.musicStarterArtistsSearch),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final artist in picks)
                    if (canSearch)
                      ActionChip(
                        label: Text(artist),
                        avatar: const Icon(Icons.search_rounded),
                        onPressed: () => _search(artist),
                      )
                    else
                      Chip(label: Text(artist)),
                ]),
              ],
              TextButton.icon(
                key: const ValueKey('music-starter-artists-edit'),
                onPressed: _editing ? null : _edit,
                icon: const Icon(Icons.edit_outlined),
                label: Text(locals.musicStarterArtistsEdit),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _StarterArtistDialog extends StatefulWidget {
  final List<String>? initial;

  const _StarterArtistDialog({required this.initial});

  @override
  State<_StarterArtistDialog> createState() => _StarterArtistDialogState();
}

class _StarterArtistDialogState extends State<_StarterArtistDialog> {
  final _name = TextEditingController();
  late final _picks = [...?widget.initial];

  String? get _candidate {
    if (_picks.length >= MusicStarterArtists.maxPicks) return null;
    final name = MusicStarterArtists.cleanName(_name.text);
    if (name == null) return null;
    final key = MusicStarterArtists.artistKey(name);
    return _picks.any((pick) => MusicStarterArtists.artistKey(pick) == key)
        ? null
        : name;
  }

  void _add() {
    final name = _candidate;
    if (name == null) return;
    setState(() {
      _picks.add(name);
      _name.clear();
    });
  }

  void _remove(String artist) => setState(() => _picks.remove(artist));

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final draft = _candidate;
    final canSave = _picks.isNotEmpty ||
        draft != null ||
        (widget.initial?.isNotEmpty ?? false);
    return AlertDialog(
      key: const ValueKey('music-starter-artists-dialog'),
      title: Text(locals.musicStarterArtists),
      scrollable: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(locals.musicStarterArtistsHint),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('music-starter-artist-input'),
            controller: _name,
            enabled: _picks.length < MusicStarterArtists.maxPicks,
            maxLength: MusicStarterArtists.maxNameLength,
            textInputAction: TextInputAction.done,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: locals.musicStarterArtistName,
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _add(),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('music-starter-artist-add'),
              onPressed: draft == null ? null : _add,
              icon: const Icon(Icons.add_rounded),
              label: Text(locals.add),
            ),
          ),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final artist in _picks)
              InputChip(
                label: Text(artist),
                onPressed: () => _remove(artist),
                onDeleted: () => _remove(artist),
              ),
          ]),
        ],
      ),
      actions: [
        if (widget.initial == null)
          TextButton(
            key: const ValueKey('music-starter-artists-skip'),
            onPressed: () => Navigator.of(context).pop(<String>[]),
            child: Text(locals.musicStarterArtistsSkip),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
        FilledButton(
          key: const ValueKey('music-starter-artists-save'),
          onPressed: canSave
              ? () => Navigator.of(context)
                  .pop([..._picks, if (draft != null) draft])
              : null,
          child: Text(locals.save),
        ),
      ],
    );
  }
}
