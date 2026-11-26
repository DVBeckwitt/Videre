import 'package:clipious/app/states/app.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:clipious/music/models/local_music_album.dart';
import 'package:clipious/music/models/local_music_album_editions.dart';
import 'package:clipious/music/models/local_music_artist.dart';
import 'package:clipious/music/models/music_artist_identity.dart';
import 'package:clipious/music/models/local_music_track.dart';
import 'package:clipious/music/models/on_device_music_entry.dart';
import 'package:clipious/music/services/local_music_library.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/music/services/music_library_service.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/views/tv/components/tv_overscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../components/music_artist_alias_dialog.dart';
import '../components/local_music_category_sort_menu.dart';
import '../components/device_music_artwork.dart';
import '../components/device_music_song_selection.dart';
import '../components/music_collection_panes.dart';
import 'music.dart';
import 'music_device_album.dart';

class MusicDeviceArtistIndexPage extends StatelessWidget {
  const MusicDeviceArtistIndexPage({super.key, this.selectionId, this.library});

  final String? selectionId;
  final LocalMusicLibrary? library;

  @override
  Widget build(BuildContext context) =>
      MusicDeviceArtistPage._(selectionId: selectionId, library: library);
}

/// Browses an artist's contributions within the active device music source.
class MusicDeviceArtistPage extends StatefulWidget {
  const MusicDeviceArtistPage({
    super.key,
    required this.selectionId,
    required String this.artistKey,
    this.anchorId,
    this.library,
  });

  const MusicDeviceArtistPage._({this.selectionId, this.library})
      : artistKey = null,
        anchorId = null;

  final String? selectionId;
  final String? artistKey;
  final String? anchorId;
  final LocalMusicLibrary? library;

  @override
  State<MusicDeviceArtistPage> createState() => _MusicDeviceArtistPageState();
}

class _MusicDeviceArtistPageState extends State<MusicDeviceArtistPage> {
  static const _albumArtistsOnlySetting =
      'music-device-artist-index-album-artists-only';

  static const _orderSetting = 'music-device-artist-index-order';

  late final AppCubit _app;
  late final AppState _session;
  bool _checking = true;
  int _request = 0;

  LocalMusicLibrary get _library =>
      widget.library ?? LocalMusicLibrary.instance;

  MusicLibraryService get _aliases =>
      MusicLibraryService.forProfile(db, db.profileId);

  bool get _isCurrent {
    if (!mounted ||
        _app.isClosed ||
        !identical(_app, context.read<AppCubit>())) {
      return false;
    }
    final current = _app.state;
    return !current.globalLoading &&
        !current.sessionRecoveryRequired &&
        current.profileId == _session.profileId &&
        db.profileId == _session.profileId &&
        current.sessionRevision == _session.sessionRevision &&
        current.server == _session.server;
  }

  bool get _sourceCurrent =>
      _isCurrent && _library.acceptsSessionSelection(widget.selectionId);

  LocalMusicArtist? get _currentArtist {
    final key = widget.artistKey;
    if (!_sourceCurrent || key == null) return null;
    if (widget.anchorId case final anchorId?) {
      final anchor = _library.trackById(anchorId);
      if (anchor == null || localMusicArtistCredit(anchor, key) == null) {
        return null;
      }
    }
    return findLocalMusicArtist(_library.visibleTracks, key);
  }

  @override
  void initState() {
    super.initState();
    _app = context.read<AppCubit>();
    _session = _app.state;
    _load();
  }

  @override
  void didUpdateWidget(MusicDeviceArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library ||
        oldWidget.selectionId != widget.selectionId) {
      _load();
    }
  }

  Future<void> _load({bool refresh = false}) async {
    final request = ++_request;
    final library = _library;
    bool active() => request == _request && _isCurrent;
    if (!active()) return;
    if (!_checking) setState(() => _checking = true);
    try {
      await library.initialize();
      if (!active() || library.selectionId != widget.selectionId) return;
      await library.revalidate();
      if (!active() || !_sourceCurrent) return;
      if (refresh || !library.loaded) await library.refresh();
    } finally {
      if (mounted && request == _request) setState(() => _checking = false);
    }
  }

  Widget _unavailable(AppLocalizations locals) {
    final library = _library;
    final message = !_sourceCurrent
        ? (library.isSystem && library.selectionId == widget.selectionId
            ? locals.localMusicAndroidLibraryUnavailable
            : locals.localMusicFolderUnavailable)
        : (library.error == null
            ? locals.musicNoResults
            : library.isSystem
                ? locals.localMusicAndroidLibraryError
                : locals.localMusicFolderError);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(message, textAlign: TextAlign.center),
        ),
        TextButton(
          autofocus: isTv,
          onPressed: () => _load(refresh: true),
          child: Text(locals.retry),
        ),
      ]),
    );
  }

  Future<void> _editAlias(LocalMusicArtist artist) async {
    final database = db;
    final library = _library;
    final selection = widget.selectionId;
    final anchor = widget.anchorId;
    bool current() =>
        mounted &&
        !_checking &&
        identical(database, db) &&
        identical(library, _library) &&
        selection == widget.selectionId &&
        anchor == widget.anchorId &&
        _currentArtist?.key == artist.key;
    if (!current()) return;
    await showMusicArtistAliasEditor(
      context,
      library: _aliases,
      identity: MusicArtistIdentity.device(artist.key),
      originalName: artist.name,
      isCurrent: current,
    );
  }

  Future<void> _play(String? id) async {
    final artist = _checking ? null : _currentArtist;
    if (artist == null) return;
    final tracks = artist.tracks;
    final index = id == null ? 0 : tracks.indexWhere((t) => t.playbackId == id);
    if (index < 0) return;
    final library = _library;
    final selection = widget.selectionId;
    bool current() =>
        _sourceCurrent &&
        library == _library &&
        selection == widget.selectionId &&
        artist.key == widget.artistKey &&
        tracks.every((track) =>
            identical(library.visibleTrackById(track.playbackId), track));
    try {
      await MusicScreen.playOnDeviceTracks(
        context,
        tracks.map(OnDeviceMusicEntry.device).toList(),
        startIndex: index,
        queueTitle: artist.name,
        songTap: id != null,
        isCurrent: current,
      );
    } catch (_) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(AppLocalizations.of(context)!.musicPlaybackError)));
      }
    }
  }

  Widget _filteredIndex(BuildContext context, AppLocalizations locals,
      List<LocalMusicArtist> artists, MusicLibraryService aliases) {
    final settings = context.read<SettingsCubit?>();
    final albumArtistsOnly = context.select((SettingsCubit? settings) =>
        settings?.state.settings[_albumArtistsOnlySetting]?.value == 'true');
    final visibleArtists = albumArtistsOnly
        ? artists.where((artist) => artist.hasAlbumArtistCredit).toList()
        : artists;
    return Column(
      children: [
        if (settings != null)
          SwitchListTile(
            autofocus: isTv && visibleArtists.isEmpty,
            title: Text(locals.localMusicShowOnlyAlbumArtists),
            value: albumArtistsOnly,
            onChanged: (value) async {
              if (!_sourceCurrent || settings.isClosed) return;
              try {
                await settings.setMusicCollectionPreference(
                    _albumArtistsOnlySetting, value.toString());
              } catch (_) {
                if (!context.mounted || !_sourceCurrent) return;
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(locals.musicLibraryActionError)));
              }
            },
          ),
        Expanded(
          child: visibleArtists.isEmpty
              ? Center(child: Text(locals.musicNoResults))
              : _index(visibleArtists, aliases),
        ),
      ],
    );
  }

  ListView _index(List<LocalMusicArtist> artists, MusicLibraryService aliases) {
    final indexes = {
      for (final (index, artist) in artists.indexed)
        ValueKey(artist.key): index,
    };
    return ListView.builder(
      itemCount: artists.length,
      findChildIndexCallback: (key) => indexes[key],
      itemBuilder: (context, index) {
        final artist = artists[index];
        final displayName = aliases.artistDisplayName(
            MusicArtistIdentity.device(artist.key), artist.name);
        return ListTile(
          key: ValueKey(artist.key),
          autofocus: isTv && index == 0,
          leading: DeviceMusicCoverMosaic(
            tracks: artist.tracks,
            fallbackIcon: Icons.person_outline,
          ),
          title:
              Text(displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: displayName == artist.name
              ? null
              : Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            if (!_sourceCurrent) return;
            MusicScreen.openDeviceCollection(
              context,
              MusicDeviceArtistPage(
                artistKey: artist.key,
                selectionId: widget.selectionId,
                library: _library,
              ),
            );
          },
        );
      },
    );
  }

  Widget _artist(AppLocalizations locals, LocalMusicArtist artist,
      MusicLibraryService aliases, DeviceMusicSongSelectionState selection) {
    final members = artist.tracks;
    final albumKeys = members.map((track) => track.albumKey).nonNulls.toSet();
    // Read the release kind from the whole visible release, including tracks
    // on which this artist has no credit.
    final albums = browseLocalMusicAlbumEditions(
      groupLocalMusicAlbums(_library.visibleTracks
          .where((track) => albumKeys.contains(track.albumKey))),
      _library.albumEditionGroups,
    );
    final releases = <LocalMusicReleaseKind?, List<LocalMusicAlbum>>{};
    for (final album in albums) {
      (releases[album.releaseKind] ??= []).add(album);
    }
    final playAll = Padding(
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: FilledButton.icon(
          onPressed: () => _play(null),
          icon: const Icon(Icons.play_arrow),
          label: Text(locals.musicPlayAll),
        ),
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        playAll,
        for (final kind in [...LocalMusicReleaseKind.values, null])
          if (releases[kind] case final section?)
            ExpansionTile(
              key: PageStorageKey((
                'music-device-artist-releases',
                widget.selectionId,
                artist.key,
                kind,
              )),
              title: Text(_releaseSectionLabel(locals, kind)),
              leading: const Icon(Icons.album_outlined),
              children:
                  section.map((album) => _releaseTile(album, aliases)).toList(),
            ),
      ],
    );
    return MusicCollectionPanes(
      details: details,
      buildTracks: (context, split) => ListView.builder(
        key: PageStorageKey((
          'music-device-artist-tracks',
          widget.selectionId,
          widget.artistKey,
        )),
        itemCount: members.length + (split ? 0 : 1),
        itemBuilder: (context, index) {
          if (!split && index == 0) return details;
          final trackIndex = split ? index : index - 1;
          final track = members[trackIndex];
          final selected = selection.active
              ? selection.contains(trackIndex)
              : track.playbackId == widget.anchorId;
          return ListTile(
            key: ValueKey(track.playbackId),
            autofocus: isTv && trackIndex == 0,
            selected: selected,
            leading: Icon(selection.active
                ? (selected ? Icons.check_box : Icons.check_box_outline_blank)
                : (selected ? Icons.music_note : Icons.audiotrack_outlined)),
            title:
                Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                ...localMusicArtistCredit(track, artist.key)!
                    .roles
                    .map((role) => localMusicArtistRoleLabel(locals, role)),
                if (track.album case final album?) album,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: selection.active
                ? () => selection.toggle(trackIndex)
                : () => _play(track.playbackId),
            onLongPress: () => selection.start(trackIndex),
          );
        },
      ),
    );
  }

  String _releaseSectionLabel(
          AppLocalizations locals, LocalMusicReleaseKind? kind) =>
      switch (kind) {
        LocalMusicReleaseKind.album => locals.localMusicBrowseAlbums,
        LocalMusicReleaseKind.ep => locals.localMusicArtistEps,
        LocalMusicReleaseKind.single => locals.localMusicArtistSingles,
        LocalMusicReleaseKind.live => locals.localMusicArtistLiveReleases,
        LocalMusicReleaseKind.compilation =>
          locals.localMusicArtistCompilations,
        LocalMusicReleaseKind.remix => locals.localMusicArtistRemixes,
        LocalMusicReleaseKind.soundtrack => locals.localMusicArtistSoundtracks,
        LocalMusicReleaseKind.djMix => locals.localMusicArtistDjMixes,
        LocalMusicReleaseKind.mixtape => locals.localMusicArtistMixtapes,
        LocalMusicReleaseKind.demo => locals.localMusicArtistDemos,
        null => locals.localMusicArtistUnclassifiedReleases,
      };

  Widget _releaseTile(LocalMusicAlbum album, MusicLibraryService aliases) =>
      ListTile(
        key: ValueKey(album.key),
        title: Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: _releaseByline(album, aliases),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          if (!_sourceCurrent) return;
          MusicScreen.openDeviceCollection(
            context,
            MusicDeviceAlbumPage(
              selectionId: widget.selectionId,
              albumKey: album.key,
              library: _library,
            ),
          );
        },
      );

  Widget? _releaseByline(LocalMusicAlbum album, MusicLibraryService aliases) {
    final artist = album.albumArtist;
    final artistKey = localMusicArtistKey(artist);
    final displayName = artist == null || artistKey == null
        ? artist
        : aliases.artistDisplayName(
            MusicArtistIdentity.device(artistKey), artist);
    final labels = [displayName, album.releaseDate].nonNulls.join(' · ');
    return labels.isEmpty
        ? null
        : Text(labels, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppCubit>();
    final locals = AppLocalizations.of(context)!;
    final aliases = _aliases;
    return ListenableBuilder(
      listenable: Listenable.merge([_library, aliases.changes]),
      builder: (context, _) {
        final index = widget.artistKey == null;
        final order = index
            ? LocalMusicCategorySortMenu.readOrder(context, _orderSetting)
            : null;
        final artist = _checking ? null : _currentArtist;
        final title = artist == null
            ? locals.localMusicBrowseArtists
            : aliases.artistDisplayName(
                MusicArtistIdentity.device(artist.key), artist.name);
        return DeviceMusicSongSelection(
          library: _library,
          tracks: artist?.tracks ?? const [],
          source: (_library, widget.selectionId, widget.artistKey, _request),
          currentTracks: () => _checking ? null : _currentArtist?.tracks,
          builder: (context, selection) {
            final Widget body;
            if (!_isCurrent) {
              body = Center(child: Text(locals.musicSourceUnavailable));
            } else if (_checking) {
              body = const Center(child: CircularProgressIndicator());
            } else if (artist != null) {
              body = _artist(locals, artist, aliases, selection);
            } else if (order != null &&
                _sourceCurrent &&
                _library.error == null) {
              final artists = order.order(
                groupLocalMusicArtists(_library.visibleTracks),
                name: (artist) => aliases.artistDisplayName(
                    MusicArtistIdentity.device(artist.key), artist.name),
                key: (artist) => artist.key,
                tracks: (artist) => artist.tracks,
              );
              body = _filteredIndex(context, locals, artists, aliases);
            } else {
              body = _unavailable(locals);
            }
            final page = Scaffold(
              appBar: AppBar(
                title: Text(title),
                actions: [
                  if (selection.selectButton case final button?) button,
                  if (order != null)
                    LocalMusicCategorySortMenu(
                      settingName: _orderSetting,
                      order: order,
                      isCurrent: () =>
                          _sourceCurrent &&
                          !_checking &&
                          _library.error == null,
                    ),
                  if (artist != null &&
                      MusicArtistIdentity.device(artist.key).isValid)
                    IconButton(
                      key: const ValueKey('music-edit-device-artist-alias'),
                      tooltip: locals.musicEditArtistAlias,
                      onPressed: () => _editAlias(artist),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                ],
              ),
              body: SafeArea(
                child: Column(children: [
                  if (selection.toolbar case final toolbar?) toolbar,
                  Expanded(child: body),
                ]),
              ),
            );
            return Shortcuts(
              shortcuts: {
                for (final key in selectKeys)
                  SingleActivator(key): const ActivateIntent(),
              },
              child: isTv ? TvOverscan(child: page) : page,
            );
          },
        );
      },
    );
  }
}

String localMusicArtistRoleLabel(
        AppLocalizations locals, LocalMusicArtistRole role) =>
    switch (role) {
      LocalMusicArtistRole.trackArtist => locals.localMusicTrackArtistCredit,
      LocalMusicArtistRole.albumArtist => locals.localMusicAlbumArtistCredit,
    };
