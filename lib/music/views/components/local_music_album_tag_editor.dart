import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import 'local_music_tag_editor.dart' show localMusicTagErrorMessage;

Future<void> editLocalMusicAlbumTags(
  BuildContext context,
  LocalMusicLibrary library,
  List<LocalMusicTrack> tracks, {
  required bool Function() isCurrent,
}) async {
  if (!context.mounted || !isCurrent() || !tracks.any(library.canEditTags)) {
    return;
  }
  final targets = [
    for (final track in tracks)
      _AlbumTagTrack(track, eligible: library.canEditTags(track)),
  ];
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: _AlbumTagEditor(
        library: library,
        tracks: targets,
        isCurrent: isCurrent,
      ),
    ),
  );
}

class _AlbumTagTrack {
  _AlbumTagTrack(this.track, {required this.eligible});

  final LocalMusicTrack track;
  final bool eligible;
  LocalMusicTags? original;
  bool selected = false;
  final numbers = <String, String?>{};
  bool coverChanged = false;
  String? readError;
  String? writeError;
  _FileOutcome? outcome;

  bool get canEditArtwork => original?.canEditArtwork ?? false;
}

typedef _AlbumTagChange = ({
  _AlbumTagTrack target,
  Map<String, String?> tags,
  LocalMusicArtworkEdit? artwork,
});

enum _EditorStep { loading, edit, review, applying, results }

enum _FileOutcome { excluded, unchanged, skipped, saving, saved }

class _AlbumTagEditor extends StatefulWidget {
  const _AlbumTagEditor({
    required this.library,
    required this.tracks,
    required this.isCurrent,
  });

  final LocalMusicLibrary library;
  final List<_AlbumTagTrack> tracks;
  final bool Function() isCurrent;

  @override
  State<_AlbumTagEditor> createState() => _AlbumTagEditorState();
}

class _AlbumTagEditorState extends State<_AlbumTagEditor> {
  static const _sharedFields = [
    'album',
    'albumArtist',
    'artist',
    'genre',
    'releaseDate'
  ];

  final _sharedTags = <String, String>{};
  _EditorStep _step = _EditorStep.loading;
  List<_AlbumTagChange> _reviewed = const [];
  LocalMusicArtworkEdit? _artwork;
  String? _artworkError;
  bool _pickingArtwork = false;
  bool _stopRequested = false;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    for (final target in widget.tracks) {
      if (!mounted) return;
      if (!target.eligible) {
        target.readError = 'TAGS_UNSUPPORTED';
        continue;
      }
      if (!widget.isCurrent()) {
        target.readError = 'TAGS_CHANGED';
        continue;
      }
      try {
        target.original = await widget.library.readTags(target.track);
        if (target.original == null || !widget.isCurrent()) {
          target.original = null;
          target.readError = 'TAGS_CHANGED';
        }
        target.selected = target.original != null;
      } on PlatformException catch (error) {
        target.readError = error.code;
      } catch (_) {
        target.readError = 'TAGS_READ_FAILED';
      }
    }
    if (mounted) setState(() => _step = _EditorStep.edit);
  }

  Iterable<_AlbumTagTrack> get _selected =>
      widget.tracks.where((target) => target.selected);

  List<_AlbumTagChange> _changes() {
    final changes = <_AlbumTagChange>[];
    final sharedTags = _sharedTags.map(
      (field, value) =>
          MapEntry(field, LocalMusicTags.normalizeChange(field, value)),
    );
    for (final target in _selected) {
      final original = target.original!;
      final tags = {
        for (final entry in sharedTags.entries)
          if (entry.value != original.values[entry.key]) entry.key: entry.value,
        ...target.numbers,
      };
      final artwork =
          _artwork?.image != null || original.hasArtwork ? _artwork : null;
      if (tags.isNotEmpty || artwork != null) {
        changes.add((target: target, tags: tags, artwork: artwork));
      }
    }
    return changes;
  }

  bool get _canEditArtwork =>
      _selected.isNotEmpty &&
      _selected.every((target) => target.canEditArtwork);

  bool get _canRemoveArtwork =>
      _selected.any((target) => target.original!.canRemoveArtwork) &&
      _selected.every((target) =>
          !target.original!.hasArtwork || target.original!.canRemoveArtwork);

  bool get _canApplyArtwork =>
      _artwork == null ||
      (_artwork?.image == null ? _canRemoveArtwork : _canEditArtwork);

  Future<void> _pickArtwork() async {
    if (_pickingArtwork || !_canEditArtwork || !widget.isCurrent()) return;
    setState(() {
      _pickingArtwork = true;
      _artworkError = null;
    });
    try {
      final bytes = await widget.library.pickTagArtwork();
      if (!mounted || bytes == null || !widget.isCurrent()) return;
      setState(() => _artwork = LocalMusicArtworkEdit.replace(bytes));
    } on PlatformException catch (error) {
      if (mounted) setState(() => _artworkError = error.code);
    } catch (_) {
      if (mounted) setState(() => _artworkError = 'TAGS_ARTWORK_PICK_FAILED');
    } finally {
      if (mounted) setState(() => _pickingArtwork = false);
    }
  }

  Future<void> _apply() async {
    if (_step != _EditorStep.review) return;
    FocusScope.of(context).unfocus();
    setState(() {
      for (final target in widget.tracks) {
        target.outcome =
            target.selected ? _FileOutcome.unchanged : _FileOutcome.excluded;
      }
      for (final change in _reviewed) {
        change.target.outcome = null;
        change.target.coverChanged = change.artwork?.image != null;
      }
      _step = _EditorStep.applying;
    });
    for (final (:target, :tags, :artwork) in _reviewed) {
      if (!mounted) return;
      if (_stopRequested) {
        setState(() => target.outcome = _FileOutcome.skipped);
        continue;
      }
      if (!widget.isCurrent() ||
          widget.library.visibleTrackById(target.track.playbackId) == null) {
        setState(() => target.writeError = 'TAGS_CHANGED');
        continue;
      }
      setState(() => target.outcome = _FileOutcome.saving);
      try {
        final saved = await widget.library
            .editTags(target.track, target.original!, tags, artwork: artwork);
        if (!mounted) return;
        setState(() {
          if (saved) {
            target.outcome = _FileOutcome.saved;
          } else {
            target.writeError = 'TAGS_DECLINED';
          }
        });
      } on PlatformException catch (error) {
        if (mounted) setState(() => target.writeError = error.code);
      } catch (_) {
        if (mounted) setState(() => target.writeError = 'TAGS_WRITE_FAILED');
      }
    }
    if (mounted) setState(() => _step = _EditorStep.results);
  }

  String _status(AppLocalizations locals, _AlbumTagTrack target) {
    if (target.readError case final error?) {
      return localMusicTagErrorMessage(locals, error, reading: true);
    }
    if (target.writeError case final error?) {
      return localMusicTagErrorMessage(
        locals,
        error,
        reading: false,
        replacingArtwork: target.coverChanged,
      );
    }
    return switch (target.outcome) {
      _FileOutcome.excluded => locals.localMusicBatchExcluded,
      _FileOutcome.unchanged => locals.localMusicBatchUnchanged,
      _FileOutcome.skipped => locals.localMusicBatchSkipped,
      _FileOutcome.saving => locals.localMusicTagsSaving,
      _FileOutcome.saved => locals.localMusicTagsSaved,
      null => locals.localMusicBatchPending,
    };
  }

  String _fieldLabel(AppLocalizations locals, String field) => switch (field) {
        'album' => locals.localMusicSortAlbum,
        'albumArtist' => locals.localMusicTagAlbumArtist,
        'artist' => locals.localMusicSortArtist,
        'genre' => locals.localMusicTagGenre,
        'releaseDate' => locals.localMusicTagReleaseDate,
        'trackNumber' => locals.localMusicTagTrackNumber,
        'trackTotal' => locals.localMusicTagTrackTotal,
        'discNumber' => locals.localMusicTagDiscNumber,
        'discTotal' => locals.localMusicTagDiscTotal,
        _ => field,
      };

  String? _sharedTagError(AppLocalizations locals, String field) {
    if (!_sharedTags.containsKey(field)) return null;
    if (_selected
        .any((target) => !target.original!.editableFields.contains(field))) {
      return locals.localMusicBatchTagUnavailable;
    }
    if (field != 'releaseDate') return null;
    final date = LocalMusicTags.normalizeChange(field, _sharedTags[field]);
    if (_selected.any((target) {
      final original = target.original!;
      return date != original.values[field] &&
          !original.acceptsReleaseDate(date);
    })) {
      return _selected.any((target) => !target.original!.allowsMonthReleaseDate)
          ? locals.localMusicTagLegacyDateFormats
          : locals.localMusicTagReleaseDateFormats;
    }
    return null;
  }

  Widget _sharedField(AppLocalizations locals, String field) {
    final enabled = _sharedTags.containsKey(field);
    final error = _sharedTagError(locals, field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          title: Text(_fieldLabel(locals, field)),
          controlAffinity: ListTileControlAffinity.leading,
          value: enabled,
          onChanged: (value) => setState(() {
            if (value == true) {
              _sharedTags[field] = '';
            } else {
              _sharedTags.remove(field);
            }
          }),
        ),
        if (enabled)
          TextFormField(
            key: ValueKey(field),
            initialValue: _sharedTags[field],
            decoration: InputDecoration(
              labelText: _fieldLabel(locals, field),
              helperText:
                  error == null ? locals.localMusicBatchBlankRemoves : null,
              errorText: error,
              errorMaxLines: 3,
            ),
            onChanged: (value) => setState(() => _sharedTags[field] = value),
          ),
      ],
    );
  }

  Widget _artworkField(AppLocalizations locals) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_artwork?.image case final bytes?)
            _coverPreview(locals, bytes)
          else if (_artwork != null)
            Text(locals.localMusicTagArtworkRemoving),
          if (_artworkError case final error?)
            Text(localMusicTagErrorMessage(locals, error, reading: true)),
          if (!_canApplyArtwork) Text(locals.localMusicBatchArtworkUnavailable),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed:
                    _canEditArtwork && !_pickingArtwork ? _pickArtwork : null,
                child: Text(locals.localMusicTagChooseArtwork),
              ),
              if (_selected.any((target) => target.original!.hasArtwork))
                TextButton(
                  onPressed: !_canRemoveArtwork || _pickingArtwork
                      ? null
                      : () => setState(() {
                            _artwork = const LocalMusicArtworkEdit.remove();
                            _artworkError = null;
                          }),
                  child: Text(locals.localMusicTagRemoveArtwork),
                ),
              if (_artwork != null)
                TextButton(
                  onPressed: _pickingArtwork
                      ? null
                      : () => setState(() {
                            _artwork = null;
                            _artworkError = null;
                          }),
                  child: Text(locals.localMusicBatchKeepArtwork),
                ),
            ],
          ),
        ],
      );

  Widget _coverPreview(AppLocalizations locals, Uint8List bytes) =>
      Image.memory(
        bytes,
        width: 64,
        height: 64,
        fit: BoxFit.contain,
        cacheWidth: 128,
        semanticLabel: locals.musicCoverLabel,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );

  Widget _trackField(AppLocalizations locals, _AlbumTagTrack target) {
    final original = target.original;
    if (original == null) {
      return ListTile(
        title: Text(target.track.title),
        subtitle: Text(_fileDetails(target, _status(locals, target))),
      );
    }
    final invalid = original.validateNumberChanges(target.numbers);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          title: Text(target.track.title),
          subtitle: Text(_fileDetails(
              target,
              target.canEditArtwork
                  ? null
                  : locals.localMusicBatchFileArtworkUnavailable)),
          controlAffinity: ListTileControlAffinity.leading,
          value: target.selected,
          onChanged: (value) =>
              setState(() => target.selected = value ?? false),
        ),
        if (target.selected)
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (final field in LocalMusicTags.numberFields)
                if (original.editableFields.contains(field))
                  SizedBox(
                    width: 122,
                    child: TextFormField(
                      key: ValueKey((target.track.playbackId, field)),
                      initialValue: target.numbers.containsKey(field)
                          ? target.numbers[field]
                          : original.values[field],
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: _fieldLabel(locals, field),
                        errorText: invalid == field
                            ? locals.localMusicBatchInvalidNumber
                            : null,
                      ),
                      onChanged: (value) => setState(() {
                        final number = value.isEmpty ? null : value;
                        if (number == original.values[field]) {
                          target.numbers.remove(field);
                        } else {
                          target.numbers[field] = number;
                        }
                      }),
                    ),
                  ),
            ],
          ),
      ],
    );
  }

  String _fileDetails(_AlbumTagTrack target, String? description) => [
        if (target.track.fileName case final name?) name,
        if (description != null) description,
      ].join('\n');

  Widget _reviewTile(AppLocalizations locals, _AlbumTagChange change) =>
      ListTile(
        title: Text(change.target.track.title),
        subtitle: Text(_fileDetails(
          change.target,
          [
            for (final entry in change.tags.entries)
              locals.localMusicBatchTagChange(
                _fieldLabel(locals, entry.key),
                entry.value ?? locals.localMusicBatchTagRemoved,
              ),
            if (change.artwork != null)
              change.artwork?.image == null
                  ? locals.localMusicTagRemoveArtwork
                  : locals.localMusicTagReplaceArtwork,
          ].join('\n'),
        )),
      );

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final closeLabel = MaterialLocalizations.of(context).closeButtonLabel;
    final isCurrent = widget.isCurrent();
    final applying = _step == _EditorStep.applying;
    final editing = _step == _EditorStep.edit;
    final reviewing = _step == _EditorStep.review;
    final changes = editing ? _changes() : const <_AlbumTagChange>[];
    final canReview = isCurrent &&
        !_pickingArtwork &&
        changes.isNotEmpty &&
        _canApplyArtwork &&
        _sharedTags.keys
            .every((field) => _sharedTagError(locals, field) == null) &&
        _selected.every((target) =>
            target.original!.validateNumberChanges(target.numbers) == null);
    final Widget content;
    switch (_step) {
      case _EditorStep.loading:
        content = LinearProgressIndicator(
            semanticsLabel: locals.localMusicTagsLoading);
      case _EditorStep.edit:
        content = ListView.builder(
          key: const PageStorageKey('album-tag-edit'),
          itemCount: widget.tracks.length + 1,
          itemBuilder: (context, index) {
            if (index != 0) {
              return _trackField(locals, widget.tracks[index - 1]);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(locals.localMusicBatchEditHelp),
                for (final field in _sharedFields) _sharedField(locals, field),
                _artworkField(locals),
                const Divider(),
              ],
            );
          },
        );
      case _EditorStep.review:
        content = ListView.builder(
          key: const ValueKey(_EditorStep.review),
          itemCount: _reviewed.length + 1,
          itemBuilder: (context, index) => index == 0
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(locals.localMusicBatchReviewHelp(_reviewed.length)),
                    if (_artwork?.image case final bytes?)
                      _coverPreview(locals, bytes),
                  ],
                )
              : _reviewTile(locals, _reviewed[index - 1]),
        );
      case _EditorStep.applying:
      case _EditorStep.results:
        content = ListView.builder(
          key: const ValueKey(_EditorStep.results),
          itemCount: widget.tracks.length,
          itemBuilder: (context, index) {
            final target = widget.tracks[index];
            return ListTile(
              title: Text(target.track.title),
              subtitle: Text(_fileDetails(target, _status(locals, target))),
            );
          },
        );
    }
    return PopScope<void>(
      canPop: !applying,
      child: AlertDialog(
        title: Text(switch (_step) {
          _EditorStep.review => locals.localMusicBatchReview,
          _EditorStep.applying => locals.localMusicTagsSaving,
          _EditorStep.results => locals.localMusicBatchResults,
          _ => locals.localMusicBatchEditTags,
        }),
        content: SizedBox(
          width: 540,
          height: _step == _EditorStep.loading ? null : 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!isCurrent) Text(locals.localMusicTagsChanged),
              if (applying)
                LinearProgressIndicator(
                    semanticsLabel: locals.localMusicTagsSaving),
              Flexible(child: content),
            ],
          ),
        ),
        actions: [
          if (!applying)
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context),
              child: Text(
                  _step == _EditorStep.results ? closeLabel : locals.cancel),
            ),
          if (applying)
            TextButton(
              onPressed: _stopRequested
                  ? null
                  : () => setState(() => _stopRequested = true),
              child: Text(locals.localMusicBatchStop),
            ),
          if (reviewing)
            TextButton(
              onPressed: () => setState(() => _step = _EditorStep.edit),
              child: Text(MaterialLocalizations.of(context).backButtonTooltip),
            ),
          if (editing)
            FilledButton(
              onPressed: !canReview
                  ? null
                  : () {
                      FocusScope.of(context).unfocus();
                      setState(() {
                        _reviewed = changes;
                        _step = _EditorStep.review;
                      });
                    },
              child: Text(locals.localMusicBatchReview),
            ),
          if (reviewing)
            FilledButton(
              onPressed: isCurrent ? _apply : null,
              child: Text(locals.localMusicBatchApply),
            ),
        ],
      ),
    );
  }
}
