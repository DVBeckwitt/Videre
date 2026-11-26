import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../router.dart';
import '../../../utils.dart' show selectKeys;
import '../../../utils/interfaces/db.dart';
import '../../../utils/motion.dart';
import '../../../utils/views/components/channel_avatar.dart';
import '../../models/music_catalog_search.dart';
import '../../services/music_catalog_service.dart';
import '../../services/music_starter_artists.dart';

class MusicStarterArtistsSection extends StatelessWidget {
  const MusicStarterArtistsSection({super.key})
      : _settings = false,
        focusNode = null;

  const MusicStarterArtistsSection.settings({super.key, this.focusNode})
      : _settings = true;

  final bool _settings;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppCubit>();
    final session = app.state;
    final database = db;
    if (!_sameSession(app, database, session)) return const SizedBox.shrink();
    return _ProfileStarterArtists(
      key: ValueKey((database, session.profileId, session.sessionRevision)),
      app: app,
      database: database,
      session: session,
      settings: _settings,
      focusNode: focusNode,
    );
  }
}

bool _sameSession(AppCubit app, IDbClient database, AppState initial,
    {AppState? emitted}) {
  if (app.isClosed || !identical(database, db)) return false;
  final current = emitted ?? app.state;
  return !current.globalLoading &&
      !current.sessionRecoveryRequired &&
      current.profileId == database.profileId &&
      current.profileId == initial.profileId &&
      current.sessionRevision == initial.sessionRevision &&
      current.server == initial.server;
}

ChannelAvatar _avatar(MusicStarterArtistPick artist, double size) =>
    ChannelAvatar(
      name: artist.name,
      images: artist.thumbnails,
      musicArtwork: true,
      instanceOnly: true,
      size: size,
    );

class _ProfileStarterArtists extends StatefulWidget {
  final AppCubit app;
  final IDbClient database;
  final AppState session;
  final bool settings;
  final FocusNode? focusNode;

  const _ProfileStarterArtists({
    super.key,
    required this.app,
    required this.database,
    required this.session,
    required this.settings,
    this.focusNode,
  });

  @override
  State<_ProfileStarterArtists> createState() => _ProfileStarterArtistsState();
}

class _ProfileStarterArtistsState extends State<_ProfileStarterArtists> {
  late final _artists =
      MusicStarterArtists(widget.database, widget.session.profileId);
  bool _editing = false;

  Future<void> _edit() async {
    final app = widget.app;
    final database = widget.database;
    final session = widget.session;
    bool current() => _sameSession(app, database, session);
    if (_editing || !current()) return;
    setState(() => _editing = true);
    try {
      final picks = await showDialog<List<MusicStarterArtistPick>>(
        context: context,
        useRootNavigator: false,
        animationStyle: AppMotion.dialogStyle(context),
        builder: (_) => _StarterArtistDialog(
          app: app,
          database: database,
          session: session,
          initial: _artists.picks,
        ),
      );
      if (mounted && current() && picks != null) await _artists.save(picks);
    } catch (_) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)!.recommendationError),
        ));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  void _openArtist(MusicStarterArtistPick artist) {
    if (!_sameSession(widget.app, widget.database, widget.session) ||
        widget.session.server == null ||
        !(_artists.picks?.any((pick) => pick.key == artist.key) ?? false)) {
      return;
    }
    final id = artist.catalogId;
    context.router.push(id == null
        ? MusicRoute(initialQuery: artist.name)
        : MusicRoute(artistId: id));
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    if (widget.settings) {
      return Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: ListTile(
          key: const ValueKey('music-starter-artists-setting'),
          focusNode: widget.focusNode,
          leading: const Icon(Icons.person_add_alt_1_outlined),
          title: Text(locals.musicStarterArtists),
          subtitle: Text(locals.musicStarterArtistsHint),
          onTap: _editing ? null : _edit,
        ),
      );
    }
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
                if (canSearch &&
                    picks.any((artist) => artist.catalogId == null))
                  Text(locals.musicStarterArtistsSearch),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  for (final artist in picks)
                    if (canSearch)
                      ActionChip(
                        key: ValueKey(artist.key),
                        label: Text(artist.name),
                        avatar: artist.catalogId == null
                            ? const Icon(Icons.search_rounded)
                            : _avatar(artist, 24),
                        onPressed: () => _openArtist(artist),
                      )
                    else
                      Chip(
                        key: ValueKey(artist.key),
                        label: Text(artist.name),
                        avatar: _avatar(artist, 24),
                      ),
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
  final AppCubit app;
  final IDbClient database;
  final AppState session;
  final List<MusicStarterArtistPick>? initial;

  const _StarterArtistDialog({
    required this.app,
    required this.database,
    required this.session,
    required this.initial,
  });

  @override
  State<_StarterArtistDialog> createState() => _StarterArtistDialogState();
}

enum _SearchStatus { idle, loading, success, failed }

class _StarterArtistDialogState extends State<_StarterArtistDialog> {
  static const _debounceDelay = Duration(milliseconds: 300);
  static const _resultLimit = 8;

  final _catalog = musicCatalogService;
  final _name = TextEditingController();
  late final _picks = [...?widget.initial];
  List<MusicStarterArtistPick> _results = const [];
  _SearchStatus _status = _SearchStatus.idle;
  Timer? _debounce;
  int _generation = 0;
  bool _invalidated = false;

  bool get _current =>
      !_invalidated &&
      identical(_catalog, musicCatalogService) &&
      _sameSession(widget.app, widget.database, widget.session);

  bool get _hasSpace => _picks.length < MusicStarterArtists.maxPicks;

  void _cancelSearch() {
    _debounce?.cancel();
    _generation++;
  }

  void _changeQuery(String text) {
    _cancelSearch();
    final query = MusicStarterArtists.cleanName(text);
    final server = widget.session.server;
    final canSearch = _current && _hasSpace && query != null && server != null;
    setState(() {
      _status = canSearch ? _SearchStatus.loading : _SearchStatus.idle;
      _results = const [];
    });
    if (!canSearch) return;
    final generation = _generation;
    _debounce = Timer(_debounceDelay, () async {
      bool current() => mounted && _current && generation == _generation;
      if (!current()) return;
      try {
        final page = await _catalog.searchPage(
            query, MusicCatalogSearchType.artists, 1,
            isCurrent: current);
        if (!current()) return;
        final seen = <String>{};
        final results = <MusicStarterArtistPick>[];
        for (final hit in page.hits.whereType<MusicCatalogArtistHit>()) {
          final pick = MusicStarterArtistPick.fromCatalog(hit.artist, server);
          if (pick == null || !seen.add(pick.catalogId!)) continue;
          results.add(pick);
          if (results.length == _resultLimit) break;
        }
        setState(() {
          _status = _SearchStatus.success;
          _results = results;
        });
      } catch (_) {
        if (current()) setState(() => _status = _SearchStatus.failed);
      }
    });
  }

  bool _selected(MusicStarterArtistPick result) =>
      _picks.any((pick) => pick.key == result.key);

  void _select(MusicStarterArtistPick result) {
    if (!_current ||
        !_hasSpace ||
        !_results.contains(result) ||
        _selected(result)) {
      return;
    }
    final nameKey = MusicStarterArtists.artistKey(result.name);
    final legacy = _picks.indexWhere((pick) =>
        pick.catalogId == null &&
        MusicStarterArtists.artistKey(pick.name) == nameKey);
    _cancelSearch();
    setState(() {
      if (legacy < 0) {
        _picks.add(result);
      } else {
        _picks[legacy] = result;
      }
      _name.clear();
      _status = _SearchStatus.idle;
      _results = const [];
    });
  }

  void _remove(MusicStarterArtistPick artist) {
    if (_current) setState(() => _picks.remove(artist));
  }

  void _finish([List<MusicStarterArtistPick>? picks]) {
    if (picks != null && !_current) return;
    _cancelSearch();
    Navigator.of(context).pop(picks);
  }

  @override
  void dispose() {
    _cancelSearch();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final active = _current;
    final canSearch = active && widget.session.server != null;
    final canSave =
        active && (_picks.isNotEmpty || (widget.initial?.isNotEmpty ?? false));
    return BlocListener<AppCubit, AppState>(
      bloc: widget.app,
      listener: (context, state) {
        if (_invalidated ||
            _sameSession(widget.app, widget.database, widget.session,
                emitted: state)) {
          return;
        }
        _cancelSearch();
        setState(() => _invalidated = true);
      },
      child: Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: AlertDialog(
          key: const ValueKey('music-starter-artists-dialog'),
          title: Text(locals.musicStarterArtists),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!active)
                Text(locals.musicDetailsConnectionChanged)
              else ...[
                Text(locals.musicStarterArtistsHint),
                if (_picks.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final artist in _picks)
                      InputChip(
                        key: ValueKey(artist.key),
                        label: Text(artist.name),
                        avatar: _avatar(artist, 24),
                        onPressed: () => _remove(artist),
                        onDeleted: () => _remove(artist),
                      ),
                  ]),
                ],
                const SizedBox(height: 12),
                if (canSearch)
                  TextField(
                    key: const ValueKey('music-starter-artist-input'),
                    controller: _name,
                    enabled: _hasSpace,
                    maxLength: MusicStarterArtists.maxNameLength,
                    textInputAction: TextInputAction.done,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      labelText: locals.musicStarterArtistName,
                      counterText: '',
                    ),
                    onChanged: _changeQuery,
                  )
                else
                  Text(locals.musicStarterArtistsConnect),
                if (_status == _SearchStatus.loading)
                  const LinearProgressIndicator(),
                if (_status == _SearchStatus.failed)
                  Text(locals.musicCatalogError),
                if (_status == _SearchStatus.success && _results.isEmpty)
                  Text(locals.musicNoResults),
                for (final result in _results)
                  ListTile(
                    key: ValueKey(
                        'music-starter-artist-result-${result.catalogId}'),
                    contentPadding: EdgeInsets.zero,
                    leading: _avatar(result, 40),
                    title: Text(result.name),
                    trailing: Icon(_selected(result) ? Icons.check : Icons.add),
                    enabled: !_selected(result),
                    onTap: _selected(result) ? null : () => _select(result),
                  ),
              ],
            ],
          ),
          actions: [
            if (active && widget.initial == null)
              TextButton(
                key: const ValueKey('music-starter-artists-skip'),
                onPressed: () => _finish(const []),
                child: Text(locals.musicStarterArtistsSkip),
              )
            else
              TextButton(
                onPressed: _finish,
                child: Text(locals.cancel),
              ),
            FilledButton(
              key: const ValueKey('music-starter-artists-save'),
              onPressed: canSave ? () => _finish([..._picks]) : null,
              child: Text(locals.save),
            ),
          ],
        ),
      ),
    );
  }
}
