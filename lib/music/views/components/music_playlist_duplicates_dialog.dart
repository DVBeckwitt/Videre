import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';

typedef _Occurrence = ({int position, Video song});

class MusicPlaylistDuplicatesDialog extends StatefulWidget {
  const MusicPlaylistDuplicatesDialog({
    super.key,
    required this.entries,
    required this.titleFor,
  });

  final List<Video> entries;
  final String Function(Video) titleFor;

  @override
  State<MusicPlaylistDuplicatesDialog> createState() =>
      _MusicPlaylistDuplicatesDialogState();
}

class _MusicPlaylistDuplicatesDialogState
    extends State<MusicPlaylistDuplicatesDialog> {
  late final _groups = _findGroups();
  late final _selected = {
    for (final group in _groups)
      for (final occurrence in group.skip(1)) occurrence.song.indexId!,
  };

  List<List<_Occurrence>> _findGroups() {
    final groups = <String, List<_Occurrence>>{};
    for (final (index, song) in widget.entries.indexed) {
      if (song.musicMetadata == null ||
          song.indexId == null ||
          song.videoId.isEmpty) {
        continue;
      }
      groups.putIfAbsent(song.videoId, () => []).add(
        (position: index + 1, song: song),
      );
    }
    return groups.values.where((group) => group.length > 1).toList();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(locals.musicPlaylistFindDuplicates),
      scrollable: true,
      content: _groups.isEmpty
          ? Text(locals.musicPlaylistNoDuplicates)
          : SizedBox(
              width: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(locals.musicPlaylistDuplicatesReview),
                  for (final group in _groups) ...[
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Semantics(
                        header: true,
                        child: Text(widget.titleFor(group.first.song)),
                      ),
                      subtitle: Text(group.first.song.musicMetadata!.artist),
                    ),
                    Text(locals.musicPlaylistDuplicateKeepPosition(
                        group.first.position)),
                    for (final (:position, :song) in group.skip(1))
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(locals
                            .musicPlaylistDuplicateRemovePosition(position)),
                        value: _selected.contains(song.indexId),
                        onChanged: (checked) => setState(() {
                          if (checked == true) {
                            _selected.add(song.indexId!);
                          } else {
                            _selected.remove(song.indexId);
                          }
                        }),
                      ),
                  ],
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_groups.isEmpty
              ? MaterialLocalizations.of(context).okButtonLabel
              : locals.cancel),
        ),
        if (_groups.isNotEmpty)
          FilledButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(Set.of(_selected)),
            child: Text(locals.musicPlaylistRemoveDuplicates),
          ),
      ],
    );
  }
}
