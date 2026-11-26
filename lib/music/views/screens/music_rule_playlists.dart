import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_library_entry.dart';
import 'package:clipious/music/models/music_recording_rating.dart';
import 'package:clipious/music/models/music_rule_playlist.dart';
import 'package:clipious/music/services/music_recording_rating_store.dart';
import 'package:clipious/music/services/music_rule_playlist_store.dart';
import 'package:clipious/music/views/components/music_library_actions.dart';
import 'package:clipious/music/views/components/music_offline_filter.dart';
import 'package:clipious/music/views/screens/music.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';

class MusicRulePlaylistsButton extends StatelessWidget {
  const MusicRulePlaylistsButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        key: const ValueKey('music-rule-playlists'),
        tooltip: AppLocalizations.of(context)!.musicRulePlaylists,
        icon: const Icon(Icons.rule),
        onPressed: () {
          final session = MusicLibrarySession(context.read<AppCubit>());
          if (!session.isCurrent) return;
          final store =
              MusicRulePlaylistStore.forProfile(db, session.library.profileId);
          final ratingStore = MusicRecordingRatingStore.forProfile(
              db, session.library.profileId);
          Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => _RulePlaylistsPage(
                  session: session, store: store, ratingStore: ratingStore)));
        },
      );
}

class _RulePlaylistsPage extends StatelessWidget {
  final MusicLibrarySession session;
  final MusicRulePlaylistStore store;
  final MusicRecordingRatingStore ratingStore;
  final String? playlistId;

  const _RulePlaylistsPage({
    required this.session,
    required this.store,
    required this.ratingStore,
    this.playlistId,
  });

  MusicRulePlaylist? get _playlist => playlistId == null
      ? null
      : store.playlists.where((item) => item.id == playlistId).firstOrNull;

  Future<T?> _showDialog<T>(BuildContext context, WidgetBuilder builder) =>
      showDialog<T>(
        context: context,
        builder: (_) => BlocBuilder<AppCubit, AppState>(
          bloc: session.app,
          builder: (context, _) {
            if (session.isCurrent) return builder(context);
            final locals = AppLocalizations.of(context)!;
            return AlertDialog(
              content: Text(locals.musicSourceUnavailable),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                        MaterialLocalizations.of(context).closeButtonLabel)),
              ],
            );
          },
        ),
      );

  Future<void> _edit(BuildContext context,
      [MusicRulePlaylist? previous]) async {
    if (!session.isCurrent) return;
    final playlist = await _showDialog<MusicRulePlaylist>(
        context, (_) => _RulePlaylistEditor(previous: previous));
    if (playlist == null || !context.mounted || !session.isCurrent) return;
    try {
      await store.save(playlist,
          previous: previous,
          isCurrent: () => context.mounted && session.isCurrent);
    } catch (_) {
      if (context.mounted && session.isCurrent) _showError(context);
    }
  }

  Future<void> _delete(BuildContext context, MusicRulePlaylist playlist) async {
    if (!session.isCurrent) return;
    final locals = AppLocalizations.of(context)!;
    final confirm = await _showDialog<bool>(
      context,
      (dialogContext) => AlertDialog(
        title: Text(locals.musicRulePlaylistDelete),
        content: Text(playlist.name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(locals.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(locals.delete)),
        ],
      ),
    );
    if (confirm != true || !context.mounted || !session.isCurrent) return;
    try {
      await store.remove(playlist,
          isCurrent: () => context.mounted && session.isCurrent);
      if (context.mounted &&
          session.isCurrent &&
          ModalRoute.isCurrentOf(context) == true) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (context.mounted && session.isCurrent) _showError(context);
    }
  }

  Future<void> _play(BuildContext context, {String? songId}) async {
    if (!session.isCurrent) return;
    final playlist = _playlist;
    if (playlist == null) return;
    final songs = _resolve(playlist);
    final start =
        songId == null ? 0 : songs.indexWhere((song) => song.id == songId);
    if (songs.isEmpty || start < 0) return;
    try {
      await MusicScreen.playTracks(
          context, [for (final song in songs) song.toVideo()],
          queueTitle: playlist.name,
          startIndex: start,
          songTap: songId != null,
          collectionDetail: true);
    } catch (_) {
      if (context.mounted && session.isCurrent) {
        _showError(context, playback: true);
      }
    }
  }

  void _showError(BuildContext context, {bool playback = false}) {
    final locals = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(playback
            ? locals.musicPlaybackError
            : locals.musicLibraryActionError)));
  }

  List<MusicLibraryEntry> _resolve(MusicRulePlaylist playlist) =>
      playlist.resolve(session.library.entries, ratings: ratingStore.ratings);

  @override
  Widget build(BuildContext context) => BlocBuilder<AppCubit, AppState>(
        bloc: session.app,
        builder: (context, _) => ListenableBuilder(
          listenable: Listenable.merge(
              [store.changes, session.library.changes, ratingStore.changes]),
          builder: (context, _) {
            final locals = AppLocalizations.of(context)!;
            final playlist = session.isCurrent ? _playlist : null;
            final available =
                session.isCurrent && (playlistId == null || playlist != null);
            return Scaffold(
              appBar: AppBar(
                title: Text(playlist?.name ?? locals.musicRulePlaylists),
                actions: [
                  if (available &&
                      playlistId == null &&
                      store.playlists.isNotEmpty)
                    IconButton(
                      key: const ValueKey('music-rule-playlist-create'),
                      tooltip: locals.musicRulePlaylistCreate,
                      icon: const Icon(Icons.playlist_add_rounded),
                      onPressed: () => _edit(context),
                    ),
                  if (playlist != null) ...[
                    IconButton(
                      key: const ValueKey('music-rule-playlist-edit'),
                      tooltip: locals.musicRulePlaylistEdit,
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(context, playlist),
                    ),
                    IconButton(
                      tooltip: locals.delete,
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(context, playlist),
                    ),
                  ],
                ],
              ),
              body: SafeArea(
                child: available
                    ? playlist == null
                        ? _catalog(context, locals)
                        : _detail(locals, playlist)
                    : Center(child: Text(locals.musicSourceUnavailable)),
              ),
            );
          },
        ),
      );

  Widget _catalog(BuildContext context, AppLocalizations locals) {
    final playlists = store.playlists;
    if (playlists.isEmpty) {
      return Center(
        child: FilledButton.icon(
          key: const ValueKey('music-rule-playlist-create'),
          onPressed: () => _edit(context),
          icon: const Icon(Icons.playlist_add_rounded),
          label: Text(locals.musicRulePlaylistCreate),
        ),
      );
    }
    return ListView.builder(
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return ListTile(
          key: ValueKey(playlist.id),
          leading: const Icon(Icons.rule),
          title: Text(playlist.name),
          onTap: () {
            if (!session.isCurrent) return;
            Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => _RulePlaylistsPage(
                    session: session,
                    store: store,
                    ratingStore: ratingStore,
                    playlistId: playlist.id)));
          },
        );
      },
    );
  }

  Widget _detail(AppLocalizations locals, MusicRulePlaylist playlist) {
    final songs = _resolve(playlist);
    return MusicOfflineFilter(
      key: ValueKey(playlist.id),
      videos: [for (final song in songs) song.toVideo()],
      builder: (context, offline) {
        final visible = [
          for (final (index, song) in songs.indexed)
            if (!offline.enabled || offline.entries?[index] != null) song,
        ];

        Future<void> play([int? index]) async {
          if (!offline.enabled) {
            await _play(context,
                songId: index == null ? null : visible[index].id);
            return;
          }
          bool isCurrent() => session.isCurrent && offline.isCurrent();
          final tracks = offline.entries?.nonNulls.toList();
          if (tracks == null || tracks.isEmpty || !isCurrent()) return;
          try {
            await MusicScreen.playCollectionTracks(context, tracks,
                queueTitle: playlist.name,
                startIndex: index ?? 0,
                isCurrent: isCurrent);
          } catch (_) {
            if (context.mounted && isCurrent()) {
              _showError(context, playback: true);
            }
          }
        }

        return Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  key: const ValueKey('music-rule-playlist-play'),
                  onPressed: visible.isEmpty ? null : () => play(),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(locals.musicPlayAll),
                ),
                musicOfflineFilterButton(context, offline,
                    key: const ValueKey('music-rule-playlist-offline')),
              ],
            ),
          ),
          Expanded(
            child: visible.isEmpty
                ? offline.enabled
                    ? musicOfflineCollectionEmpty(context, offline)
                    : Center(child: Text(locals.musicRulePlaylistEmpty))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final song = visible[index];
                      return ListTile(
                        key: ValueKey('music-rule-playlist-track-${song.id}'),
                        title: Text(song.title),
                        subtitle:
                            song.subtitle.isEmpty ? null : Text(song.subtitle),
                        onTap: () => play(index),
                      );
                    },
                  ),
          ),
        ]);
      },
    );
  }
}

class _RulePlaylistEditor extends StatefulWidget {
  final MusicRulePlaylist? previous;

  const _RulePlaylistEditor({required this.previous});

  @override
  State<_RulePlaylistEditor> createState() => _RulePlaylistEditorState();
}

class _RulePlaylistEditorState extends State<_RulePlaylistEditor> {
  final _form = GlobalKey<FormState>();

  late final _name = TextEditingController(text: widget.previous?.name);
  late final _title =
      TextEditingController(text: widget.previous?.titleContains);
  late final _artist =
      TextEditingController(text: widget.previous?.artistContains);
  late final _album =
      TextEditingController(text: widget.previous?.albumContains);
  late final _minimum = TextEditingController(
      text: widget.previous?.minimumDurationSeconds?.toString());
  late final _maximum = TextEditingController(
      text: widget.previous?.maximumDurationSeconds?.toString());
  late final _limit =
      TextEditingController(text: widget.previous?.limit?.toString());
  late int? _minimumRating = widget.previous?.minimumRating;
  late var _sort = widget.previous?.sort ?? MusicRulePlaylistSort.saved;
  late var _descending = widget.previous?.descending ?? false;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _title,
      _artist,
      _album,
      _minimum,
      _maximum,
      _limit
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _number(TextEditingController controller) =>
      int.tryParse(controller.text.trim(), radix: 10);

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
        context,
        MusicRulePlaylist(
          id: widget.previous?.id ?? const Uuid().v4(),
          name: _name.text.trim(),
          titleContains: _title.text.trim(),
          artistContains: _artist.text.trim(),
          albumContains: _album.text.trim(),
          minimumDurationSeconds: _number(_minimum),
          maximumDurationSeconds: _number(_maximum),
          minimumRating: _minimumRating,
          sort: _sort,
          descending: _descending,
          limit: _number(_limit),
        ));
  }

  String _sortLabel(AppLocalizations locals, MusicRulePlaylistSort sort) =>
      switch (sort) {
        MusicRulePlaylistSort.saved => locals.musicLibrarySavedOrder,
        MusicRulePlaylistSort.title => locals.musicLibraryTitleOrder,
        MusicRulePlaylistSort.artist => locals.localMusicSortArtist,
        MusicRulePlaylistSort.album => locals.localMusicSortAlbum,
        MusicRulePlaylistSort.duration => locals.searchDuration,
      };

  Widget _textField(String key, TextEditingController controller, String label,
          {String? Function(String?)? validator}) =>
      TextFormField(
        key: ValueKey('music-rule-playlist-$key'),
        controller: controller,
        maxLength: musicRulePlaylistTextLimit,
        decoration: InputDecoration(labelText: label, counterText: ''),
        textInputAction: TextInputAction.next,
        validator: validator,
      );

  Widget _numberField(AppLocalizations locals, String key,
      TextEditingController controller, String label, int minimum, int maximum,
      {String? Function(int)? validateValue}) {
    return TextFormField(
      key: ValueKey('music-rule-playlist-$key'),
      controller: controller,
      decoration: InputDecoration(labelText: label),
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      validator: (text) {
        if (text == null || text.trim().isEmpty) return null;
        final value = _number(controller);
        if (value == null || value < minimum || value > maximum) {
          return locals.musicRulePlaylistNumberRange(minimum, maximum);
        }
        return validateValue?.call(value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.previous == null
          ? locals.musicRulePlaylistCreate
          : locals.musicRulePlaylistEdit),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(locals.musicRulePlaylistIntro),
            _textField('name', _name, locals.name,
                validator: (text) => text == null || text.trim().isEmpty
                    ? locals.musicRulePlaylistNameRequired
                    : null),
            _textField('title', _title, locals.musicRulePlaylistTitle),
            _textField('artist', _artist, locals.musicRulePlaylistArtist),
            _textField('album', _album, locals.musicRulePlaylistAlbum),
            _numberField(
                locals,
                'minimum',
                _minimum,
                locals.musicRulePlaylistMinimumDuration,
                0,
                musicRulePlaylistMaximumDuration),
            _numberField(
                locals,
                'maximum',
                _maximum,
                locals.musicRulePlaylistMaximumDuration,
                0,
                musicRulePlaylistMaximumDuration,
                validateValue: (value) => value < (_number(_minimum) ?? 0)
                    ? locals.musicRulePlaylistDurationRange
                    : null),
            DropdownButtonFormField<int>(
              key: const ValueKey('music-rule-playlist-minimum-rating'),
              initialValue: _minimumRating,
              isExpanded: true,
              decoration: InputDecoration(
                  labelText: locals.musicRulePlaylistMinimumRating),
              hint: Text(locals.musicRulePlaylistAnyRating),
              items: [
                DropdownMenuItem(
                    child: Text(locals.musicRulePlaylistAnyRating)),
                for (var rating = musicMinimumRecordingRating;
                    rating <= musicMaximumRecordingRating;
                    rating++)
                  DropdownMenuItem(
                      value: rating,
                      child: Text(locals.musicRecordingRatingStars(rating))),
              ],
              onChanged: (rating) => _minimumRating = rating,
            ),
            DropdownButtonFormField<MusicRulePlaylistSort>(
              key: const ValueKey('music-rule-playlist-sort'),
              initialValue: _sort,
              isExpanded: true,
              decoration: InputDecoration(labelText: locals.searchSortBy),
              items: [
                for (final sort in MusicRulePlaylistSort.values)
                  DropdownMenuItem(
                      value: sort, child: Text(_sortLabel(locals, sort))),
              ],
              onChanged: (sort) {
                if (sort != null) _sort = sort;
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(locals.musicRulePlaylistReverseOrder),
              value: _descending,
              onChanged: (descending) =>
                  setState(() => _descending = descending),
            ),
            _numberField(locals, 'limit', _limit, locals.musicRulePlaylistLimit,
                1, musicLibraryMaximumEntries),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel)),
        FilledButton(
          key: const ValueKey('music-rule-playlist-save'),
          onPressed: _save,
          child: Text(locals.save),
        ),
      ],
    );
  }
}
