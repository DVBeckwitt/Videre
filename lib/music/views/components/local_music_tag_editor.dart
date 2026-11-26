import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';
import '../../services/local_music_lyrics_authoring.dart';

enum _SaveResult { tags, lyrics }

Future<void> editLocalMusicTags(
  BuildContext context,
  LocalMusicLibrary library,
  LocalMusicTrack track, {
  required bool Function() isCurrent,
  LocalMusicLyricsAuthoring? authoring,
}) async {
  if (!context.mounted || !isCurrent() || !library.canEditTags(track)) return;
  final saved = await showDialog<_SaveResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: _TagEditor(
        library: library,
        track: track,
        isCurrent: isCurrent,
        authoring: authoring,
      ),
    ),
  );
  if (context.mounted && isCurrent() && saved != null) {
    final locals = AppLocalizations.of(context)!;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(saved == _SaveResult.lyrics
          ? locals.localMusicEmbedLyricsSaved
          : locals.localMusicTagsSaved),
    ));
  }
}

String localMusicTagErrorMessage(
  AppLocalizations locals,
  String error, {
  required bool reading,
  bool replacingArtwork = false,
}) =>
    switch (error) {
      'TAGS_UNSUPPORTED' => reading
          ? locals.localMusicTagsUnsupported
          : locals.localMusicTagsWriteError,
      'TAGS_CHANGED' => locals.localMusicTagsChanged,
      'LYRICS_NO_SPACE' => locals.localMusicEmbedLyricsNoSpace,
      'LYRICS_MISSING' => locals.localMusicEmbedLyricsMissing,
      'LYRICS_TIMED_ONLY' => locals.localMusicEmbedLyricsTimedOnly,
      'LYRICS_DRAFT_CHANGED' => locals.localMusicEmbedLyricsDraftChanged,
      'TAGS_NO_SPACE' => !replacingArtwork
          ? locals.localMusicTagsNoSpace
          : locals.localMusicTagArtworkNoSpace,
      'TAGS_ARTWORK_INVALID' ||
      'FILE_TOO_LARGE' =>
        locals.localMusicTagArtworkInvalid,
      'TAGS_ARTWORK_PICK_FAILED' ||
      'NO_FILE_PICKER' ||
      'FILE_ACCESS' ||
      'FILE_BUSY' ||
      'FILE_IO' =>
        locals.localMusicTagArtworkPickError,
      'TAGS_INVALID_NUMBER' => locals.localMusicTagInvalidNumber,
      'TAGS_INVALID_RELEASE_DATE' => locals.localMusicTagInvalidReleaseDate,
      'TAGS_ACCESS' => locals.localMusicTagsAccess,
      'TAGS_DECLINED' => locals.localMusicTagsDeclined,
      'TAGS_RECOVERY_REQUIRED' => locals.localMusicTagsRecoveryRequired,
      'TAGS_SAVED_REFRESH_REQUIRED' =>
        locals.localMusicTagsSavedRefreshRequired,
      _ => reading
          ? locals.localMusicTagsReadError
          : locals.localMusicTagsWriteError,
    };

class _TagEditor extends StatefulWidget {
  const _TagEditor({
    required this.library,
    required this.track,
    required this.isCurrent,
    required this.authoring,
  });

  final LocalMusicLibrary library;
  final LocalMusicTrack track;
  final bool Function() isCurrent;
  final LocalMusicLyricsAuthoring? authoring;

  @override
  State<_TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<_TagEditor> {
  final _controllers = <String, TextEditingController>{};
  LocalMusicTags? _tags;
  LocalMusicArtworkEdit? _artwork;
  String? _error;
  bool _lyricsEmbedded = false;
  bool _saving = false;
  bool _pickingArtwork = false;

  bool get _busy => _saving || _pickingArtwork;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final tags = await widget.library.readTags(widget.track);
      if (!mounted) return;
      if (tags == null || !widget.isCurrent()) {
        setState(() => _error = 'TAGS_CHANGED');
        return;
      }
      setState(() {
        _tags = tags;
        for (final field in tags.editableFields) {
          _controllers[field] = TextEditingController(text: tags.values[field]);
        }
      });
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'TAGS_READ_FAILED');
    }
  }

  Map<String, String?> get _changes {
    final tags = _tags;
    if (tags == null) return const {};
    final changes = <String, String?>{};
    for (final entry in _controllers.entries) {
      if (entry.value.text == (tags.values[entry.key] ?? '')) continue;
      final value = LocalMusicTags.normalizeChange(entry.key, entry.value.text);
      if (value != tags.values[entry.key]) changes[entry.key] = value;
    }
    return changes;
  }

  bool get _blocked => switch (_error) {
        'TAGS_CHANGED' ||
        'TAGS_RECOVERY_REQUIRED' ||
        'TAGS_SAVED_REFRESH_REQUIRED' =>
          true,
        'TAGS_UNSUPPORTED' => _tags == null,
        _ => false,
      };

  Future<void> _pickArtwork() async {
    if (_busy || _blocked || !widget.isCurrent()) return;
    setState(() => _pickingArtwork = true);
    try {
      final image = await widget.library.pickTagArtwork();
      if (mounted && image != null) {
        setState(() {
          if (widget.isCurrent()) {
            _artwork = LocalMusicArtworkEdit.replace(image);
            _error = null;
          } else {
            _error = 'TAGS_CHANGED';
          }
        });
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.code);
    } catch (_) {
      if (mounted) setState(() => _error = 'TAGS_ARTWORK_PICK_FAILED');
    } finally {
      if (mounted) setState(() => _pickingArtwork = false);
    }
  }

  Future<void> _save() async {
    final tags = _tags;
    final changes = _changes;
    if (_busy ||
        _blocked ||
        tags == null ||
        (changes.isEmpty && _artwork == null)) {
      return;
    }
    await _write(
      _SaveResult.tags,
      () => widget.library.editTags(
        widget.track,
        tags,
        changes,
        artwork: _artwork,
      ),
    );
  }

  Future<void> _embed() async {
    final tags = _tags;
    final authoring = widget.authoring;
    if (_busy || _blocked || tags == null || authoring == null) return;
    if (!widget.isCurrent() || !authoring.current) {
      setState(() => _error = 'TAGS_CHANGED');
      return;
    }
    final text = authoring.readPlainDraft();
    if (text == null) {
      setState(() {
        _lyricsEmbedded = false;
        _error = authoring.readDraft() == null
            ? 'LYRICS_MISSING'
            : 'LYRICS_TIMED_ONLY';
      });
      return;
    }
    final target = await showDialog<({String language, String descriptor})>(
      context: context,
      builder: (_) => _LyricsPreview(text: text),
    );
    if (!mounted || target == null) return;
    if (!authoring.current) {
      setState(() => _error = 'TAGS_CHANGED');
      return;
    }
    if (authoring.readPlainDraft() != text) {
      setState(() => _error = 'LYRICS_DRAFT_CHANGED');
      return;
    }
    await _write(
      _SaveResult.lyrics,
      () => widget.library.embedPlainLyrics(
        widget.track,
        tags,
        language: target.language,
        descriptor: target.descriptor,
        text: text,
      ),
    );
  }

  Future<void> _write(_SaveResult kind, Future<bool> Function() save) async {
    if (!widget.isCurrent()) {
      setState(() => _error = 'TAGS_CHANGED');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _lyricsEmbedded = false;
    });
    FocusScope.of(context).unfocus();
    String? error;
    try {
      final saved = await save();
      if (!mounted) return;
      if (saved) {
        if (kind == _SaveResult.lyrics &&
            (_changes.isNotEmpty || _artwork != null)) {
          await _refreshAfterEmbed();
        } else {
          Navigator.pop(context, kind);
        }
        return;
      }
      error = widget.isCurrent() ? 'TAGS_DECLINED' : 'TAGS_CHANGED';
    } on PlatformException catch (failure) {
      error = kind == _SaveResult.lyrics && failure.code == 'TAGS_NO_SPACE'
          ? 'LYRICS_NO_SPACE'
          : failure.code;
    } catch (_) {
      error = 'TAGS_WRITE_FAILED';
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  Future<void> _refreshAfterEmbed() async {
    // Keep pending metadata fields and refresh the revision after the write.
    LocalMusicTags? refreshed;
    try {
      refreshed = await widget.library.readTags(widget.track);
    } catch (_) {
      // The file write succeeded. The editor needs a new snapshot before saving.
    }
    if (!mounted) return;
    if (!widget.isCurrent() || !mapEquals(refreshed?.values, _tags?.values)) {
      refreshed = null;
    }
    setState(() {
      _saving = false;
      _tags = refreshed ?? _tags;
      _error = refreshed == null ? 'TAGS_SAVED_REFRESH_REQUIRED' : null;
      _lyricsEmbedded = refreshed != null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final fields = {
      'title': locals.musicLibraryTitleOrder,
      'artist': locals.localMusicSortArtist,
      'album': locals.localMusicSortAlbum,
      'albumArtist': locals.localMusicTagAlbumArtist,
      'genre': locals.localMusicTagGenre,
      'releaseDate': locals.localMusicTagReleaseDate,
      'trackNumber': locals.localMusicTagTrackNumber,
      'trackTotal': locals.localMusicTagTrackTotal,
      'discNumber': locals.localMusicTagDiscNumber,
      'discTotal': locals.localMusicTagDiscTotal,
    };
    final loaded = _tags != null;
    final changes = _changes;
    final invalidField = _tags?.validateNumberChanges(changes);
    final invalidDate =
        _tags?.acceptsReleaseDate(changes['releaseDate']) == false;
    final dateFormats = _tags?.allowsMonthReleaseDate == true
        ? locals.localMusicTagReleaseDateFormats
        : locals.localMusicTagLegacyDateFormats;
    final canAct = !_busy && !_blocked;
    return PopScope<_SaveResult>(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(locals.localMusicEditTags),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.track.fileName ?? widget.track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            if (loaded)
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(locals.localMusicEditTagsHelp),
                      for (final field in fields.entries)
                        if (_controllers.containsKey(field.key))
                          TextField(
                            controller: _controllers[field.key],
                            enabled: canAct,
                            decoration: InputDecoration(
                              labelText: field.value,
                              helperText:
                                  field.key == 'releaseDate' && !invalidDate
                                      ? dateFormats
                                      : null,
                              errorText: switch (field.key) {
                                'releaseDate' when invalidDate => dateFormats,
                                _ when invalidField == field.key =>
                                  locals.localMusicTagInvalidNumber,
                                _ => null,
                              },
                              errorMaxLines: 3,
                            ),
                            keyboardType:
                                LocalMusicTags.numberFields.contains(field.key)
                                    ? TextInputType.number
                                    : TextInputType.text,
                            textInputAction: field.key == _controllers.keys.last
                                ? TextInputAction.done
                                : TextInputAction.next,
                            onChanged: (_) => setState(() {}),
                          ),
                      if (_tags?.canEditArtwork == true) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: canAct ? _pickArtwork : null,
                              child: Text(_tags!.hasArtwork
                                  ? locals.localMusicTagReplaceArtwork
                                  : locals.localMusicTagChooseArtwork),
                            ),
                            if (_tags!.canRemoveArtwork &&
                                (_artwork == null || _artwork?.image != null))
                              TextButton(
                                onPressed: canAct
                                    ? () => setState(() {
                                          _artwork = const LocalMusicArtworkEdit
                                              .remove();
                                          _error = null;
                                        })
                                    : null,
                                child: Text(locals.localMusicTagRemoveArtwork),
                              ),
                            if (_artwork != null)
                              TextButton(
                                onPressed: canAct
                                    ? () => setState(() {
                                          _artwork = null;
                                          _error = null;
                                        })
                                    : null,
                                child: Text(locals.localMusicTagUndoArtwork),
                              ),
                          ],
                        ),
                        if (_artwork != null)
                          Semantics(
                            liveRegion: true,
                            child: Text(_artwork!.image == null
                                ? locals.localMusicTagArtworkRemoving
                                : locals.localMusicTagArtworkReplacing),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            if ((!loaded && _error == null) || _saving)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(
                  semanticsLabel: _saving
                      ? locals.localMusicTagsSaving
                      : locals.localMusicTagsLoading,
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(localMusicTagErrorMessage(
                    locals,
                    _error!,
                    reading: _tags == null,
                    replacingArtwork: _artwork?.image != null,
                  )),
                ),
              ),
            if (_lyricsEmbedded)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(locals.localMusicEmbedLyricsSaved),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(_blocked
                ? MaterialLocalizations.of(context).closeButtonLabel
                : locals.cancel),
          ),
          if (loaded && widget.authoring != null)
            TextButton(
              onPressed: canAct ? _embed : null,
              child: Text(locals.localMusicEmbedPlainLyrics),
            ),
          if (loaded)
            FilledButton(
              onPressed: canAct &&
                      (changes.isNotEmpty || _artwork != null) &&
                      invalidField == null &&
                      !invalidDate
                  ? _save
                  : null,
              child: Text(locals.save),
            ),
        ],
      ),
    );
  }
}

class _LyricsPreview extends StatefulWidget {
  const _LyricsPreview({required this.text});

  final String text;

  @override
  State<_LyricsPreview> createState() => _LyricsPreviewState();
}

class _LyricsPreviewState extends State<_LyricsPreview> {
  static final _languageCode = RegExp(r'^[a-z]{3}$');
  static final _descriptionControl = RegExp(r'[\x00-\x1F\x7F-\x9F]');
  String _language = 'und';
  String _descriptor = '';

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final canEmbed = _languageCode.hasMatch(_language) &&
        _descriptor.length <= 256 &&
        !_descriptionControl.hasMatch(_descriptor);
    return Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: AlertDialog(
        title: Text(locals.localMusicEmbedPlainLyrics),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(locals.localMusicEmbedLyricsPreviewHelp),
            TextFormField(
              initialValue: _language,
              decoration: InputDecoration(
                labelText: locals.localMusicEmbedLyricsLanguage,
                helperText: locals.localMusicEmbedLyricsLanguageHelp,
                helperMaxLines: 2,
              ),
              maxLength: 3,
              textInputAction: TextInputAction.next,
              onChanged: (value) => setState(() => _language = value),
            ),
            TextFormField(
              initialValue: _descriptor,
              decoration: InputDecoration(
                labelText: locals.localMusicEmbedLyricsDescription,
                helperText: locals.localMusicEmbedLyricsDescriptionHelp,
                helperMaxLines: 2,
              ),
              maxLength: 256,
              onChanged: (value) => setState(() => _descriptor = value),
            ),
            const SizedBox(height: 12),
            Text(widget.text, maxLines: 8, overflow: TextOverflow.ellipsis),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel),
          ),
          FilledButton(
            onPressed: canEmbed
                ? () => Navigator.pop(context, (
                      language: _language,
                      descriptor: _descriptor,
                    ))
                : null,
            child: Text(locals.localMusicEmbedLyricsConfirm),
          ),
        ],
      ),
    );
  }
}
