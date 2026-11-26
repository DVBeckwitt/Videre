import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/motion.dart';
import '../../models/music_search_text.dart';
import '../../services/local_music_library.dart';
import '../../services/m3u_documents.dart';
import '../../services/m3u_playlist.dart';
import 'music_library_actions.dart';

typedef SaveM3uTracks = Future<String> Function(
  String title,
  List<M3uIndexedTrack> tracks,
  bool Function() isCurrent,
);

Future<String?> showM3uImport(
  BuildContext context, {
  required MusicLibrarySession session,
  required SaveM3uTracks save,
  String? existingTitle,
}) {
  if (!session.isCurrent) return Future.value(null);
  return showDialog<String>(
    context: context,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => _M3uImportDialog(
      session: session,
      save: save,
      existingTitle: existingTitle,
    ),
  );
}

class _M3uImportDialog extends StatefulWidget {
  final MusicLibrarySession session;
  final SaveM3uTracks save;
  final String? existingTitle;

  const _M3uImportDialog({
    required this.session,
    required this.save,
    this.existingTitle,
  });

  @override
  State<_M3uImportDialog> createState() => _M3uImportDialogState();
}

class _M3uImportDialogState extends State<_M3uImportDialog> {
  final _relinked = <String, M3uIndexedTrack>{};
  final _library = LocalMusicLibrary.instance;
  M3uInput? _input;
  M3uIndexSnapshot? _snapshot;
  List<M3uMatch>? _matches;
  bool _saving = false;
  String? _error;

  AppLocalizations get _locals => AppLocalizations.of(context)!;
  bool get _active => mounted && ModalRoute.of(context)?.isActive == true;

  void _close([String? result]) {
    final route = ModalRoute.of<String>(context)!;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(result);
    } else {
      navigator.removeRoute(route, result);
    }
  }

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final input = await M3uDocuments.open();
      if (!_active) return;
      if (input == null) {
        _close();
        return;
      }
      final document = await compute(M3uDocument.parse, input.text);
      final snapshot = await _library.m3uIndex();
      if (!_active) return;
      if (!widget.session.isCurrent) {
        setState(() => _error = _locals.musicM3uSourceChanged);
      } else if (snapshot == null) {
        setState(() => _error = _locals.musicM3uSourceRequired);
      } else {
        setState(() {
          _input = input;
          _snapshot = snapshot;
          _matches = snapshot.index.match(document, input.location);
        });
      }
    } catch (_) {
      if (_active) setState(() => _error = _locals.musicM3uReadError);
    }
  }

  M3uIndexedTrack? _track(M3uMatch row) =>
      row.exact ?? _relinked[row.reference];

  Future<void> _relink(M3uMatch row) async {
    final picked = await showDialog<({M3uIndexedTrack? track})>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (_) => _M3uTrackPicker(
        index: _snapshot!.index,
        suggestion: row.suggestion,
        canSkip: _relinked.containsKey(row.reference),
      ),
    );
    if (!_active || picked == null) return;
    setState(() {
      if (picked.track case final track?) {
        _relinked[row.reference] = track;
      } else {
        _relinked.remove(row.reference);
      }
    });
  }

  Future<void> _save(List<M3uIndexedTrack> tracks) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final original = _snapshot!;
      final current = await _library.m3uIndex();
      if (!_active) return;
      bool isCurrent() =>
          _active &&
          widget.session.isCurrent &&
          original.isCurrent() &&
          current != null &&
          current.isCurrent();
      if (!isCurrent() || !tracks.every(current!.index.contains)) {
        setState(() => _error = _locals.musicM3uSourceChanged);
        return;
      }
      final name = _input!.name;
      final title = name.substring(0, name.lastIndexOf('.')).trim();
      final id = await widget.save(
        widget.existingTitle ??
            (title.isEmpty ? _locals.musicPlaylists : title),
        tracks,
        isCurrent,
      );
      if (_active && widget.session.isCurrent) _close(id);
    } catch (_) {
      if (_active) setState(() => _error = _locals.musicM3uSaveError);
    } finally {
      if (_active) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _matches;
    final isReplacing = widget.existingTitle != null;
    final tracks = [
      if (rows != null)
        for (final row in rows)
          if (_track(row) case final track?) track,
    ];
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(
            isReplacing ? _locals.musicM3uReimport : _locals.musicM3uImport),
        content: SizedBox(
          width: 480,
          child: switch ((_error, rows)) {
            (final error?, _) => Text(error),
            (_, null) => const Center(
                heightFactor: 1,
                child: CircularProgressIndicator(),
              ),
            (_, final matches?) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isReplacing
                      ? _locals.musicM3uReplaceNotice
                      : _input!.name),
                  if (_input!.location == null)
                    Text(_locals.musicM3uRelativeUnavailable),
                  const SizedBox(height: 8),
                  Text(_locals.musicM3uReviewCount(
                      tracks.length, matches.length - tracks.length)),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SizedBox(
                      height: 320,
                      child: ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final row = matches[index];
                          final track = _track(row);
                          final suggestion = row.suggestion;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(row.reference,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              track?.location.path ??
                                  (suggestion == null
                                      ? _locals.musicM3uUnavailable
                                      : _locals.musicM3uSuggested(
                                          suggestion.location.path)),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: row.exact == null && row.canRelink
                                ? IconButton(
                                    tooltip: _locals.musicM3uChooseTrack,
                                    onPressed:
                                        _saving ? null : () => _relink(row),
                                    icon:
                                        const Icon(Icons.find_in_page_outlined),
                                  )
                                : null,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
          },
        ),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: Text(_locals.cancel)),
          if (rows != null && _error == null)
            FilledButton(
              onPressed: _saving || tracks.isEmpty ? null : () => _save(tracks),
              child: Text(isReplacing ? _locals.musicM3uReplace : _locals.save),
            ),
        ],
      ),
    );
  }
}

class _M3uTrackPicker extends StatefulWidget {
  final M3uTrackIndex index;
  final M3uIndexedTrack? suggestion;
  final bool canSkip;

  const _M3uTrackPicker({
    required this.index,
    required this.suggestion,
    required this.canSkip,
  });

  @override
  State<_M3uTrackPicker> createState() => _M3uTrackPickerState();
}

class _M3uTrackPickerState extends State<_M3uTrackPicker> {
  List<String> _terms = const [];

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final suggestion = widget.suggestion;
    final filtered = [
      if (suggestion != null && _terms.isEmpty) suggestion,
      for (final track in widget.index.tracks)
        if ((track != suggestion || _terms.isNotEmpty) &&
            (_terms.isEmpty ||
                _terms.every(normalizeMusicSearchText(
                        '${track.track.title} ${track.location.path}')
                    .contains)))
          track,
    ];
    return AlertDialog(
      title: Text(locals.musicM3uChooseTrack),
      content: SizedBox(
        width: 480,
        height: 340,
        child: Column(children: [
          TextField(
            decoration: InputDecoration(labelText: locals.search),
            onChanged: (value) =>
                setState(() => _terms = musicSearchTerms(value)),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text(locals.musicNoResults))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final row = filtered[index];
                      return ListTile(
                        title: Text(row.track.title),
                        subtitle: Text(
                            widget.index.exportPath(row.location, null) ??
                                row.location.path),
                        onTap: () => Navigator.pop(context, (track: row)),
                      );
                    },
                  ),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel)),
        if (widget.canSkip)
          TextButton(
              onPressed: () =>
                  Navigator.pop(context, (track: null as M3uIndexedTrack?)),
              child: Text(locals.musicM3uSkipTrack)),
      ],
    );
  }
}

typedef _M3uExportSelection = ({
  M3uExportPathStyle style,
  List<String> paths,
});

class _M3uExportDialog extends StatefulWidget {
  final M3uTrackIndex index;
  final M3uLocation? destination;
  final List<M3uLocation> locations;
  final int unavailable;

  const _M3uExportDialog({
    required this.index,
    required this.destination,
    required this.locations,
    required this.unavailable,
  });

  @override
  State<_M3uExportDialog> createState() => _M3uExportDialogState();
}

class _M3uExportDialogState extends State<_M3uExportDialog> {
  M3uExportPathStyle _style = M3uExportPathStyle.automatic;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final paths = [
      for (final location in widget.locations)
        if (widget.index.exportPath(location, widget.destination, style: _style)
            case final path?)
          path,
    ];
    final selection = (style: _style, paths: paths);
    final unrepresentable = widget.locations.length - paths.length;
    final absolute = paths.where((path) => path.startsWith('/')).length;
    return AlertDialog(
      scrollable: true,
      title: Text(locals.musicM3uExport),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<M3uExportPathStyle>(
            initialValue: _style,
            isExpanded: true,
            decoration: InputDecoration(labelText: locals.musicM3uPathFormat),
            items: [
              for (final style in M3uExportPathStyle.values)
                DropdownMenuItem(
                  value: style,
                  child: Text(switch (style) {
                    M3uExportPathStyle.automatic =>
                      locals.musicM3uPathAutomatic,
                    M3uExportPathStyle.relative => locals.musicM3uPathRelative,
                    M3uExportPathStyle.absolute => locals.musicM3uPathAbsolute,
                    M3uExportPathStyle.windows => locals.musicM3uPathWindows,
                  }),
                ),
            ],
            onChanged: (style) {
              if (style != null) setState(() => _style = style);
            },
          ),
          const SizedBox(height: 12),
          Text([
            switch (_style) {
              M3uExportPathStyle.automatic => locals.musicM3uPathAutomaticHelp,
              M3uExportPathStyle.relative => locals.musicM3uPathRelativeHelp,
              M3uExportPathStyle.absolute => locals.musicM3uPathAbsoluteHelp,
              M3uExportPathStyle.windows => locals.musicM3uPathWindowsHelp,
            },
            if (widget.destination == null &&
                (_style == M3uExportPathStyle.relative ||
                    _style == M3uExportPathStyle.windows))
              locals.musicM3uExportLocationUnavailable,
            if (widget.unavailable > 0)
              locals.musicM3uExportSkipped(widget.unavailable),
            if (paths.isEmpty)
              locals.musicM3uExportFormatEmpty
            else if (unrepresentable > 0)
              locals.musicM3uExportFormatSkipped(unrepresentable),
            if (absolute > 0) locals.musicM3uExportAbsolute(absolute),
          ].join('\n\n')),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(locals.cancel),
        ),
        FilledButton(
          onPressed:
              paths.isEmpty ? null : () => Navigator.pop(context, selection),
          child: Text(locals.save),
        ),
      ],
    );
  }
}

Future<void> exportM3uPlaylist(
  BuildContext context, {
  required MusicLibrarySession session,
  required String title,
  required List<String?> deviceIds,
  required M3uIndexedTrack? Function(M3uTrackIndex, String) resolve,
}) async {
  if (!session.isCurrent) return;
  final locals = AppLocalizations.of(context)!;
  void message(String value) {
    if (context.mounted && session.isCurrent) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  M3uOutput? output;
  var saved = false;
  try {
    output = await M3uDocuments.create(title);
    if (output == null || !context.mounted || !session.isCurrent) return;
    final destination = output.location;
    final library = LocalMusicLibrary.instance;
    final snapshot = await library.m3uIndex();
    if (!context.mounted || !session.isCurrent) return;
    if (snapshot == null) {
      message(locals.musicM3uSourceRequired);
      return;
    }

    final locations = <M3uLocation>[];
    final indexed = <String, M3uIndexedTrack>{};
    for (final id in deviceIds.nonNulls) {
      final track = indexed[id] ?? resolve(snapshot.index, id);
      if (track == null) continue;
      indexed[id] = track;
      locations.add(track.location);
    }
    if (locations.isEmpty) {
      message(locals.musicM3uNoExportableTracks);
      return;
    }

    final selection = await showDialog<_M3uExportSelection>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (_) => _M3uExportDialog(
        index: snapshot.index,
        destination: destination,
        locations: locations,
        unavailable: deviceIds.length - locations.length,
      ),
    );
    if (selection == null || !context.mounted || !session.isCurrent) return;

    final current = await library.m3uIndex();
    if (!context.mounted || !session.isCurrent) return;
    final style = selection.style;
    if (!snapshot.isCurrent() ||
        current == null ||
        !current.isCurrent() ||
        !indexed.entries.every((item) {
          final before = item.value;
          final path = snapshot.index
              .exportPath(before.location, destination, style: style);
          if (path == null) return true;
          final row = resolve(current.index, item.key);
          return row?.track.uri == before.track.uri &&
              row?.location == before.location &&
              current.index
                      .exportPath(before.location, destination, style: style) ==
                  path;
        })) {
      message(locals.musicM3uSourceChanged);
      return;
    }
    await M3uDocuments.write(output, selection.paths);
    saved = true;
    message(locals.musicM3uExported);
  } catch (_) {
    message(locals.musicM3uSaveError);
  } finally {
    if (!saved && output != null) {
      try {
        await M3uDocuments.discard(output);
      } catch (_) {
        message(locals.musicM3uSaveError);
      }
    }
  }
}
