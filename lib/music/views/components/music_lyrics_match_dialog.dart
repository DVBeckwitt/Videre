import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/models/music_lyrics_match.dart';
import 'package:clipious/music/services/lrc_lyrics.dart';
import 'package:clipious/music/services/music_timed_lyrics_draft.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';

class MusicLyricsMatchDialog extends StatefulWidget {
  final MusicMetadata track;
  final int? durationSeconds;
  final MusicLyrics? currentLyrics;
  final bool hasCorrection;
  final bool Function() isCurrent;
  final MusicLyricsSearch search;
  final Future<void> Function(MusicLyricsCorrection?) save;

  const MusicLyricsMatchDialog({
    super.key,
    required this.track,
    required this.durationSeconds,
    required this.currentLyrics,
    required this.hasCorrection,
    required this.isCurrent,
    required this.search,
    required this.save,
  });

  @override
  State<MusicLyricsMatchDialog> createState() => _MusicLyricsMatchDialogState();
}

class _MusicLyricsMatchDialogState extends State<MusicLyricsMatchDialog> {
  static const _maxSearchLength = 320;
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.track.title);
  late final _artist = TextEditingController(text: widget.track.artist);
  late final _album = TextEditingController(text: widget.track.album);
  final _draft = TextEditingController();
  List<MusicLyricsMatch>? _matches;
  MusicLyricsMatch? _preview;
  MusicLyrics? _editing;
  bool _searching = false;
  bool _saving = false;
  bool _searchFailed = false;
  String? _error;
  ModalRoute<Object?>? _route;

  bool get _active =>
      mounted && _route?.isCurrent == true && widget.isCurrent();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _album.dispose();
    _draft.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (!_active ||
        _searching ||
        _saving ||
        _form.currentState?.validate() != true) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchFailed = false;
      _matches = null;
      _error = null;
    });
    try {
      final matches = await widget.search(
        trackName: _title.text,
        artistName: _artist.text,
        albumName: _album.text,
        durationSeconds: widget.durationSeconds,
        isCurrent: () => _active,
      );
      if (_active) setState(() => _matches = matches);
    } catch (_) {
      if (_active) setState(() => _searchFailed = true);
    } finally {
      if (_active) setState(() => _searching = false);
    }
  }

  Future<void> _save(MusicLyricsCorrection? correction) async {
    if (!_active || _saving) return;
    final navigator = Navigator.of(context);
    final locals = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.save(correction);
      if (_active) navigator.pop(true);
    } catch (_) {
      if (_active) {
        setState(() {
          _saving = false;
          _error = locals.musicLyricsCorrectionSaveFailed;
        });
      }
    }
  }

  void _edit(MusicLyrics lyrics) {
    final text = musicTimedLyricsDraftFrom(lyrics, includeWordTiming: false);
    if (text.isEmpty) {
      setState(
          () => _error = AppLocalizations.of(context)!.musicLyricsEditTooLong);
      return;
    }
    _draft.text = text;
    setState(() {
      _editing = lyrics;
      _error = null;
    });
  }

  void _saveEdit(MusicLyrics original) {
    final locals = AppLocalizations.of(context)!;
    final text = cleanLyricsText(_draft.text);
    if (text.isEmpty) {
      setState(() => _error = locals.musicLyricsEditMissing);
      return;
    }
    if (original.kind == MusicLyricsKind.synced) {
      final seconds = widget.durationSeconds;
      final (:lines, :wordsByCue, :displayTextByCue, :breakStarts) =
          parseEnhancedLrc(_draft.text,
              playbackDuration:
                  seconds == null ? null : Duration(seconds: seconds));
      if (!lrcFitsDuration(lines, seconds)) {
        setState(() => _error = locals.musicLyricsEditInvalidTiming);
        return;
      }
      _save(MusicLyricsCorrection(
          MusicLyrics.synced(lines,
              source: original.source,
              wordsByCue: wordsByCue,
              displayTextByCue: displayTextByCue,
              breakStarts: breakStarts),
          edited: true));
    } else {
      _save(MusicLyricsCorrection(
          MusicLyrics.plain(text, source: original.source),
          edited: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final preview = _preview;
    final editing = _editing;
    final title = editing != null
        ? locals.musicLyricsEdit
        : preview != null
            ? locals.musicLyricsPreview
            : locals.musicLyricsCorrectMatch;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        scrollable: true,
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (editing != null)
                _editor(locals, editing)
              else if (preview != null)
                _showPreview(locals, preview)
              else
                _showSearch(locals),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              if (_saving) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _back,
            child: Text(editing == null && preview == null
                ? locals.cancel
                : MaterialLocalizations.of(context).backButtonTooltip),
          ),
          if (editing != null)
            FilledButton(
              onPressed: _saving ? null : () => _saveEdit(editing),
              child: Text(locals.save),
            )
          else if (preview != null)
            FilledButton(
              onPressed: _saving
                  ? null
                  : () => _save(MusicLyricsCorrection(preview.lyrics)),
              child: Text(locals.musicLyricsUseMatch),
            ),
        ],
      ),
    );
  }

  void _back() {
    if (_editing == null && _preview == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      if (_editing != null) {
        _editing = null;
      } else {
        _preview = null;
      }
      _error = null;
    });
  }

  Widget _showSearch(AppLocalizations locals) {
    final available = widget.currentLyrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(locals.musicLyricsSearchDisclosure),
        const SizedBox(height: 12),
        Form(
          key: _form,
          child: Column(
            children: [
              _searchField(_title, locals.musicLyricsTrackTitle,
                  required: true),
              _searchField(_artist, locals.musicLyricsArtist),
              _searchField(_album, locals.musicLyricsAlbum),
            ],
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton.icon(
            onPressed: _searching || _saving ? null : _search,
            icon: const Icon(Icons.search),
            label: Text(locals.search),
          ),
        ),
        if (_searching) const LinearProgressIndicator(),
        if (_searchFailed) Text(locals.musicLyricsSearchFailed),
        if (_matches case final matches?)
          if (matches.isEmpty)
            Text(locals.musicLyricsNoMatches)
          else
            for (final match in matches)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(match.trackName),
                subtitle: Text(_matchDetails(locals, match)),
                trailing: const Icon(Icons.chevron_right),
                onTap: _saving
                    ? null
                    : () => setState(() {
                          _preview = match;
                          _error = null;
                        }),
              ),
        if (available != null &&
            available.kind != MusicLyricsKind.unavailable) ...[
          const Divider(),
          Wrap(
            children: [
              if (available.kind != MusicLyricsKind.instrumental)
                TextButton(
                  onPressed:
                      _saving || _searching ? null : () => _edit(available),
                  child: Text(locals.musicLyricsEdit),
                ),
              TextButton(
                onPressed: _saving || _searching
                    ? null
                    : () => _save(const MusicLyricsCorrection(
                          MusicLyrics.unavailable(),
                        )),
                child: Text(locals.musicLyricsDiscardMatch),
              ),
            ],
          ),
        ],
        if (widget.hasCorrection)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _saving || _searching ? null : () => _save(null),
              child: Text(locals.musicLyricsRestoreAutomatic),
            ),
          ),
      ],
    );
  }

  Widget _searchField(TextEditingController controller, String label,
      {bool required = false}) {
    final locals = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        controller: controller,
        enabled: !_searching && !_saving,
        maxLength: _maxSearchLength,
        decoration: InputDecoration(labelText: label, counterText: ''),
        textInputAction: required ? TextInputAction.next : TextInputAction.done,
        onFieldSubmitted: required ? null : (_) => _search(),
        validator: (value) {
          final text = cleanLyricsText(value);
          if (required && text.isEmpty) {
            return locals.musicLyricsTrackTitleRequired;
          }
          if ((value?.length ?? 0) > _maxSearchLength) {
            return locals.musicLyricsSearchFieldTooLong;
          }
          return null;
        },
      ),
    );
  }

  Widget _showPreview(AppLocalizations locals, MusicLyricsMatch match) {
    final lyrics = match.lyrics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(match.trackName, style: Theme.of(context).textTheme.titleMedium),
        Text(_matchDetails(locals, match)),
        if (lyrics.source case final source?) Text(source),
        const SizedBox(height: 12),
        if (lyrics.kind == MusicLyricsKind.instrumental)
          Text(locals.musicLyricsInstrumental)
        else ...[
          Text(_previewText(lyrics)),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: _saving ? null : () => _edit(lyrics),
              child: Text(locals.musicLyricsEdit),
            ),
          ),
        ],
      ],
    );
  }

  Widget _editor(AppLocalizations locals, MusicLyrics original) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (original.source case final source?) Text(source),
        Text(locals.musicLyricsEditDisclosure),
        const SizedBox(height: 12),
        TextField(
          controller: _draft,
          enabled: !_saving,
          maxLength: maxLyricsCharacters,
          minLines: 4,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: locals.musicLyrics,
            alignLabelWithHint: true,
            helperText: original.kind == MusicLyricsKind.synced
                ? locals.musicLyricsEditTimingHint
                : null,
            helperMaxLines: 3,
            counterText: '',
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  String _matchDetails(AppLocalizations locals, MusicLyricsMatch match) {
    final kind = switch (match.lyrics.kind) {
      MusicLyricsKind.synced => locals.musicLyricsSynced,
      MusicLyricsKind.plain => locals.musicLyricsPlain,
      MusicLyricsKind.instrumental ||
      MusicLyricsKind.unavailable =>
        locals.musicLyricsInstrumental,
    };
    return [
      match.artistName,
      if (match.albumName.isNotEmpty) match.albumName,
      prettyDurationCustom(match.duration),
      kind,
    ].join(' · ');
  }
}

String _previewText(MusicLyrics lyrics) {
  final lines = lyrics.text?.split('\n') ?? lyrics.cues.map((cue) => cue.text);
  final excerpt = lines.take(16).join('\n');
  if (excerpt.length > 2400) return '${excerpt.substring(0, 2400)}…';
  return lines.length > 16 ? '$excerpt\n…' : excerpt;
}
