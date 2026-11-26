import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/motion.dart';
import '../../services/music_history_transfer.dart';
import '../../services/music_listening_history.dart';
import '../../services/spotify_music_history_import.dart';

Future<List<MusicListeningEvent>?> showMusicSpotifyHistoryPreview(
  BuildContext context,
  AppCubit app,
  bool Function() isCurrent,
  Future<SpotifyMusicHistoryPreview> Function() prepare,
) =>
    showDialog<List<MusicListeningEvent>>(
      context: context,
      animationStyle: AppMotion.dialogStyle(context),
      builder: (context) => BlocBuilder<AppCubit, AppState>(
        bloc: app,
        builder: (context, _) => _SpotifyHistoryPreview(
          isCurrent: isCurrent,
          prepare: prepare,
        ),
      ),
    );

class _SpotifyHistoryPreview extends StatefulWidget {
  final bool Function() isCurrent;
  final Future<SpotifyMusicHistoryPreview> Function() prepare;

  const _SpotifyHistoryPreview({
    required this.isCurrent,
    required this.prepare,
  });

  @override
  State<_SpotifyHistoryPreview> createState() => _SpotifyHistoryPreviewState();
}

class _SpotifyHistoryPreviewState extends State<_SpotifyHistoryPreview> {
  late final _preview = widget.prepare();
  SpotifyMusicHistoryStatus? _filter;

  String _label(AppLocalizations locals, SpotifyMusicHistoryStatus status) =>
      switch (status) {
        SpotifyMusicHistoryStatus.matched => locals.musicSpotifyHistoryMatched,
        SpotifyMusicHistoryStatus.ambiguous =>
          locals.musicSpotifyHistoryAmbiguous,
        SpotifyMusicHistoryStatus.unmatched =>
          locals.musicSpotifyHistoryUnmatched,
        SpotifyMusicHistoryStatus.duplicate =>
          locals.musicSpotifyHistoryDuplicate,
        SpotifyMusicHistoryStatus.skipped => locals.musicSpotifyHistorySkipped,
        SpotifyMusicHistoryStatus.invalid =>
          locals.musicSpotifyHistoryInvalidRow,
      };

  Widget _row(AppLocalizations locals, SpotifyMusicHistoryRow row) {
    final title = row.title;
    final instant = row.playedAt;
    final candidate = row.matches.length == 1 ? row.matches.single : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title ?? locals.musicSpotifyHistoryRowNumber(row.number),
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row.artist != null || row.album != null)
            Text([row.artist, row.album].nonNulls.join(' · '),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          if (instant != null)
            Text(instant.toIso8601String().replaceFirst('T', ' ')),
          Text(_label(locals, row.status)),
          if (row.status == SpotifyMusicHistoryStatus.matched &&
              candidate != null)
            Text(
              locals.musicSpotifyHistoryMatchLabel([
                candidate.entry.musicMetadata?.title ?? candidate.entry.title,
                candidate.entry.musicMetadata?.artist ?? candidate.entry.author,
                candidate.entry.musicMetadata?.album,
                candidate.source == MusicListeningSource.device
                    ? locals.musicHistoryDeviceFiles
                    : locals.musicHistoryCatalogAndDownloads,
              ].nonNulls.where((label) => label.isNotEmpty).join(' · ')),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (row.status == SpotifyMusicHistoryStatus.ambiguous)
            Text(locals.musicSpotifyHistoryMatches(row.matches.length)),
        ],
      ),
    );
  }

  Widget _dialog(AppLocalizations locals, Widget content,
          {List<MusicListeningEvent> events = const []}) =>
      AlertDialog(
        title: Text(locals.musicSpotifyHistoryPreview),
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel),
          ),
          if (events.isNotEmpty)
            FilledButton(
              onPressed: () {
                if (widget.isCurrent()) Navigator.pop(context, events);
              },
              child: Text(locals.musicSpotifyHistoryConfirm(events.length)),
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return FutureBuilder<SpotifyMusicHistoryPreview>(
      future: _preview,
      builder: (context, snapshot) {
        if (!widget.isCurrent()) {
          return _dialog(locals, Text(locals.musicSourceUnavailable));
        }
        if (snapshot.hasError) {
          final message = switch (snapshot.error) {
            MusicHistoryFileTooLarge() => locals.musicHistoryFileTooLarge,
            FormatException() => locals.musicSpotifyHistoryInvalidFile,
            _ => locals.musicHistoryTransferFailed,
          };
          return _dialog(locals, Text(message));
        }
        final preview = snapshot.data;
        if (preview == null) {
          return _dialog(locals, const LinearProgressIndicator());
        }
        if (preview.rows.isEmpty) {
          return _dialog(locals, Text(locals.musicHistoryFileEmpty));
        }

        final counts = <SpotifyMusicHistoryStatus, int>{};
        final visible = <SpotifyMusicHistoryRow>[];
        for (final row in preview.rows) {
          counts.update(row.status, (count) => count + 1, ifAbsent: () => 1);
          if (_filter == null || row.status == _filter) visible.add(row);
        }
        return _dialog(
          locals,
          SizedBox(
            width: 520,
            height: MediaQuery.sizeOf(context).height * .48,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(locals.musicSpotifyHistoryTimeNote),
                DropdownButton<SpotifyMusicHistoryStatus>(
                  isExpanded: true,
                  value: _filter,
                  hint: Text(
                      locals.musicSpotifyHistoryAllRows(preview.rows.length)),
                  items: [
                    DropdownMenuItem(
                      child: Text(locals
                          .musicSpotifyHistoryAllRows(preview.rows.length)),
                    ),
                    for (final status in SpotifyMusicHistoryStatus.values)
                      if (counts[status] case final count?)
                        DropdownMenuItem(
                          value: status,
                          child: Text(locals.musicSpotifyHistoryStatusCount(
                            _label(locals, status),
                            count,
                          )),
                        ),
                  ],
                  onChanged: (status) => setState(() => _filter = status),
                ),
                Expanded(
                  child: ListView.builder(
                    key: ValueKey(_filter),
                    itemCount: visible.length,
                    itemBuilder: (_, index) => _row(locals, visible[index]),
                  ),
                ),
              ],
            ),
          ),
          events: preview.events,
        );
      },
    );
  }
}
