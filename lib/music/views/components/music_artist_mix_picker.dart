import 'package:clipious/content_filter/community_models.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_artist.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';

Future<List<MusicArtist>?> showMusicArtistMixPicker(
    BuildContext context, MusicArtist initialArtist,
    {required bool Function() isCurrent}) async {
  bool current() => context.mounted && isCurrent();
  if (!current()) return null;
  final selected = await showDialog<List<MusicArtist>>(
    context: context,
    useRootNavigator: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: _ArtistMixPicker(initialArtist: initialArtist, isCurrent: current),
    ),
  );
  return current() ? selected : null;
}

MusicArtist? _canonicalArtist(MusicArtist artist) {
  final id = normalizeChannelId(artist.id);
  final name = artist.name.trim();
  if (id == null || name.isEmpty) return null;
  return MusicArtist(id: id, name: name, thumbnails: artist.thumbnails);
}

class _ArtistMixPicker extends StatefulWidget {
  const _ArtistMixPicker(
      {required this.initialArtist, required this.isCurrent});

  final MusicArtist initialArtist;
  final bool Function() isCurrent;

  @override
  State<_ArtistMixPicker> createState() => _ArtistMixPickerState();
}

class _ArtistMixPickerState extends State<_ArtistMixPicker> {
  final _query = TextEditingController();
  final _selected = <String, MusicArtist>{};
  List<MusicArtist>? _results;
  int _searchRevision = 0;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (_canonicalArtist(widget.initialArtist) case final artist?) {
      _selected[artist.id] = artist;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (!widget.isCurrent()) return;
    final query = _query.text.trim();
    final revision = ++_searchRevision;
    setState(() {
      _loading = query.isNotEmpty;
      _failed = false;
      _results = null;
    });
    if (query.isEmpty) return;

    final route = ModalRoute.of(context);
    bool current() =>
        mounted &&
        route?.isActive != false &&
        revision == _searchRevision &&
        widget.isCurrent();

    try {
      final page = await musicCatalogService.searchPage(
          query, MusicCatalogSearchType.channels, 1,
          isCurrent: current);
      if (!current()) return;
      final results = <String, MusicArtist>{};
      for (final hit in page.hits.whereType<MusicCatalogChannelHit>()) {
        if (_canonicalArtist(hit.artist) case final artist?) {
          results.putIfAbsent(artist.id, () => artist);
        }
      }
      setState(() {
        _results = results.values.toList();
        _loading = false;
      });
    } catch (_) {
      if (!current()) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  void _setSelected(MusicArtist artist, bool selected) {
    if (!widget.isCurrent()) return;
    if (!selected) {
      setState(() => _selected.remove(artist.id));
    } else if (_selected.length < MusicCatalogService.artistMixSeedLimit) {
      setState(() => _selected[artist.id] = artist);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final atLimit = _selected.length >= MusicCatalogService.artistMixSeedLimit;
    final results = _results;
    return AlertDialog(
      title: Text(locals.musicBuildArtistMix),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: locals.musicArtistMixSearch,
                suffixIcon: IconButton(
                  tooltip: locals.search,
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            if (_selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final artist in _selected.values)
                      FilterChip(
                        key: ValueKey(artist.id),
                        label: Text(artist.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        selected: true,
                        onSelected: (selected) =>
                            _setSelected(artist, selected),
                      ),
                  ],
                ),
              ),
            if (atLimit)
              Semantics(
                liveRegion: true,
                child: Text(locals.musicArtistMixSeedLimit),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              )
            else if (_failed || results?.isEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(_failed
                      ? locals.musicCatalogError
                      : locals.musicNoResults),
                ),
              )
            else if (results != null)
              for (final artist in results)
                CheckboxListTile(
                  key: ValueKey('result-${artist.id}'),
                  title: Text(artist.name),
                  contentPadding: EdgeInsets.zero,
                  value: _selected.containsKey(artist.id),
                  onChanged: !atLimit || _selected.containsKey(artist.id)
                      ? (selected) => _setSelected(artist, selected == true)
                      : null,
                ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(locals.cancel),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () {
                  if (widget.isCurrent()) {
                    Navigator.of(context)
                        .pop(List<MusicArtist>.unmodifiable(_selected.values));
                  }
                },
          child: Text(locals.musicArtistMixStart),
        ),
      ],
    );
  }
}
