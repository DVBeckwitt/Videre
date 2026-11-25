import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/main.dart' show isTv;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

typedef MusicPlaylistReorderRow = ({String id, String title, String artist});

class MusicPlaylistReorder extends StatefulWidget {
  const MusicPlaylistReorder({
    super.key,
    required this.rows,
    required this.onSave,
  });

  final List<MusicPlaylistReorderRow> rows;
  final Future<bool> Function(List<String> order) onSave;

  @override
  State<MusicPlaylistReorder> createState() => _MusicPlaylistReorderState();
}

class _MusicPlaylistReorderState extends State<MusicPlaylistReorder> {
  late final _draft = widget.rows.toList();
  bool _saving = false;
  bool _failed = false;

  void _move(MusicPlaylistReorderRow row, int to) {
    if (_saving || to < 0 || to >= _draft.length) return;
    final from = _draft.indexOf(row);
    if (from == to || from < 0) return;
    setState(() {
      _draft.insert(to, _draft.removeAt(from));
      _failed = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    var saved = false;
    try {
      saved = await widget.onSave([for (final row in _draft) row.id]);
    } catch (_) {
      // Keep the draft available if writing failed.
    }
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: locals.cancel,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
          title: Text(locals.musicPlaylistReorder),
          actions: [
            TextButton(
              key: const ValueKey('music-playlist-reorder-save'),
              onPressed:
                  _saving || listEquals(_draft, widget.rows) ? null : _save,
              child: Text(locals.save),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_saving) const LinearProgressIndicator(),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(locals.musicLibraryActionError),
                  ),
                ),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: _draft.length,
                  onReorder: (from, to) =>
                      _move(_draft[from], to > from ? to - 1 : to),
                  itemBuilder: (context, index) {
                    final row = _draft[index];
                    return ListTile(
                      key: ValueKey(row.id),
                      leading: Text('${index + 1}'),
                      title: Text(row.title),
                      subtitle: Text(row.artist),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (!isTv)
                          ReorderableDragStartListener(
                            key: ValueKey(('music-playlist-drag', row.id)),
                            index: index,
                            enabled: !_saving,
                            child: const SizedBox.square(
                              dimension: 48,
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        PopupMenuButton<bool>(
                          key: ValueKey(('music-playlist-move', row.id)),
                          tooltip:
                              '${locals.musicPlaylistMoveSong} · ${row.title}',
                          enabled: !_saving,
                          onSelected: (earlier) => _move(
                              row, _draft.indexOf(row) + (earlier ? -1 : 1)),
                          itemBuilder: (_) => [
                            if (index > 0)
                              PopupMenuItem(
                                value: true,
                                child: Text(locals.musicQueueMoveUp),
                              ),
                            if (index < _draft.length - 1)
                              PopupMenuItem(
                                value: false,
                                child: Text(locals.musicQueueMoveDown),
                              ),
                          ],
                        ),
                      ]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
