import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';

Future<void> showLocalMusicRepair(
  BuildContext context,
  LocalMusicLibrary library,
) {
  final selection = library.selectionId;
  final profile = library.visibilityProfile;
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => _withRepairKeys(
      _LocalMusicRepair(
        library: library,
        selection: selection,
        profile: profile,
      ),
    ),
  );
}

Widget _withRepairKeys(Widget child) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: child,
    );

typedef _Candidate = ({
  LocalMusicMoveCandidate match,
  LocalMusicTrack track,
  String description,
});

class _LocalMusicRepair extends StatefulWidget {
  const _LocalMusicRepair({
    required this.library,
    required this.selection,
    required this.profile,
  });

  final LocalMusicLibrary library;
  final String? selection;
  final Object? profile;

  @override
  State<_LocalMusicRepair> createState() => _LocalMusicRepairState();
}

class _LocalMusicRepairState extends State<_LocalMusicRepair> {
  LocalMusicLibrary get _library => widget.library;
  String? _missingId;
  bool _failed = false;

  bool _isCurrent() =>
      _library.acceptsSessionSelection(widget.selection) &&
      _library.visibilityProfile == widget.profile;

  void _review(String? id) {
    setState(() {
      _missingId = id;
      _failed = false;
    });
  }

  Future<void> _confirm(LocalMusicMissingTrack missing, _Candidate item) async {
    final locals = AppLocalizations.of(context)!;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => _withRepairKeys(
        AlertDialog(
          scrollable: true,
          title: Text(locals.localMusicRepairRelink),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(locals.localMusicRepairRelinkDescription),
              const SizedBox(height: 12),
              Text(
                item.track.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(item.description),
            ],
          ),
          actions: [
            TextButton(
              autofocus: isTv,
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.localMusicRepairRelink),
            ),
          ],
        ),
      ),
    );
    if (approved != true || !mounted || !_isCurrent()) return;
    final repaired = await _library.confirmMovedFileRepair(
      missing,
      item.match,
      isCurrent: _isCurrent,
    );
    if (!mounted || !_isCurrent()) return;
    if (repaired) {
      _review(null);
    } else {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: _library,
      builder: (context, _) {
        final current = _isCurrent();
        final missing = current && _missingId != null
            ? _library.missingTrackById(_missingId!)
            : null;
        final reviewing = _missingId != null;
        return PopScope(
          canPop: !reviewing,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && reviewing) _review(null);
          },
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: current && reviewing
                      ? BackButton(onPressed: () => _review(null))
                      : null,
                  title: Semantics(
                    header: true,
                    child: Text(
                      reviewing
                          ? locals.localMusicRepairPossibleMatches
                          : locals.localMusicRepairMovedFiles,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  trailing: CloseButton(
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                if (_library.busy && current) const LinearProgressIndicator(),
                Flexible(
                  child: !current || (reviewing && missing == null)
                      ? ListTile(
                          title: Text(locals.localMusicRepairReviewExpired),
                        )
                      : missing == null
                          ? _buildMissingList(locals)
                          : _buildMatchList(locals, missing),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMissingList(AppLocalizations locals) {
    final missing = _library.movedFileRepairs;
    if (missing.isEmpty) {
      return ListTile(title: Text(locals.localMusicRepairNoMissingFiles));
    }
    return ListView.builder(
      key: const ValueKey('missing-music-files'),
      shrinkWrap: true,
      itemCount: missing.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return ListTile(title: Text(locals.localMusicRepairChooseMissing));
        }
        final file = missing[index - 1];
        final description = _missingDescription(file);
        return ListTile(
          key: ValueKey(file.id),
          autofocus: isTv && index == 1,
          title: Text(file.title),
          subtitle: description.isEmpty ? null : Text(description),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _review(file.id),
        );
      },
    );
  }

  Widget _buildMatchList(
    AppLocalizations locals,
    LocalMusicMissingTrack missing,
  ) {
    final candidates = <_Candidate>[];
    final counts = <(String, String), int>{};
    for (final match in missing.candidates) {
      final track = _library.trackById(match.id);
      if (track == null || track.playbackId != match.id) continue;
      final reason = switch (match.reason) {
        LocalMusicMoveReason.revision => locals.localMusicRepairMatchRevision,
        LocalMusicMoveReason.tags => locals.localMusicRepairMatchTags,
      };
      final description = _description(
        title: track.title,
        artist: track.artist,
        album: track.album,
        fileName: track.fileName,
        folder: track.folderLocations.lastOrNull?.label,
        durationMs: track.durationMs,
        reason: reason,
      );
      candidates.add((match: match, track: track, description: description));
      counts.update(
        (track.title, description),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    bool selectable(_Candidate candidate) =>
        counts[(candidate.track.title, candidate.description)] == 1;
    final autofocus =
        isTv && !_library.busy ? candidates.indexWhere(selectable) : -1;
    final original = [
      missing.title,
      _missingDescription(missing),
    ].where((line) => line.isNotEmpty).join('\n');
    return ListView.builder(
      key: ValueKey('repair-${missing.id}'),
      shrinkWrap: true,
      itemCount: candidates.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            children: [
              ListTile(
                title: Text(locals.localMusicRepairMissingFile),
                subtitle: Text(original),
              ),
              if (_failed)
                ListTile(
                  title: Semantics(
                    liveRegion: true,
                    child: Text(locals.localMusicRepairFailed),
                  ),
                ),
              if (candidates.isEmpty)
                ListTile(title: Text(locals.localMusicRepairNoMatches)),
              if (counts.values.any((count) => count > 1))
                ListTile(
                  title: Text(locals.localMusicRepairIndistinguishableMatches),
                ),
            ],
          );
        }
        final candidate = candidates[index - 1];
        return ListTile(
          key: ValueKey(candidate.match.id),
          autofocus: index - 1 == autofocus,
          title: Text(candidate.track.title),
          subtitle: Text(candidate.description),
          trailing: const Icon(Icons.chevron_right),
          onTap: !_library.busy && selectable(candidate)
              ? () => _confirm(missing, candidate)
              : null,
        );
      },
    );
  }
}

String _missingDescription(LocalMusicMissingTrack file) => _description(
      title: file.title,
      artist: file.artist,
      album: file.album,
      fileName: file.fileName,
      folder: file.folder,
      durationMs: file.durationMs,
    );

String _description({
  required String title,
  required String? artist,
  required String? album,
  required String? fileName,
  required String? folder,
  required int durationMs,
  String? reason,
}) {
  final metadata = [
    artist,
    album,
    if (durationMs >= 1000)
      Duration(milliseconds: durationMs).toString().split('.').first,
  ].nonNulls.where((part) => part.trim().isNotEmpty).join(' • ');
  return [
    metadata,
    if (fileName != title) fileName,
    folder,
    reason,
  ].nonNulls.where((line) => line.trim().isNotEmpty).join('\n');
}
