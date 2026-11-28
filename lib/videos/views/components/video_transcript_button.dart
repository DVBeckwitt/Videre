import 'dart:async';

import 'package:clipious/utils/motion.dart';
import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class VideoTranscriptButton extends StatelessWidget {
  final Video video;
  final bool labeled;
  final bool enabled;
  final bool Function()? isCurrent;

  const VideoTranscriptButton({
    super.key,
    required this.video,
    this.labeled = false,
    this.enabled = true,
    this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final route = video.playbackConnection ?? video.backendPlayback;
    final available = enabled &&
        video.captions.isNotEmpty &&
        route?.server.profileId == route?.preferredServer.profileId;
    void open() {
      final player = context.read<PlayerCubit>();
      final opened = player.state;
      final occurrence = player.playbackOccurrenceRevision;
      final profile = db.profileId;

      bool current() {
        final state = player.state;
        return !player.isClosed &&
            db.profileId == profile &&
            player.playbackOccurrenceRevision == occurrence &&
            state.currentQueueId == opened.currentQueueId &&
            state.currentlyPlaying?.videoId == video.videoId &&
            state.isAudio == opened.isAudio &&
            !state.isClosing &&
            (isCurrent?.call() ?? true);
      }

      if (!current()) return;
      final lastSubtitles = context.read<SettingsCubit>().state.lastSubtitles;
      final localeLanguage = Localizations.localeOf(context).languageCode;
      var initialIndex = video.captions.indexWhere(
        (caption) => caption.label == lastSubtitles,
      );
      if (initialIndex < 0) {
        initialIndex = video.captions.indexWhere(
          (caption) => caption.languageCode == localeLanguage,
        );
      }
      if (initialIndex < 0) initialIndex = 0;

      showSafeModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => FractionallySizedBox(
          widthFactor: 1,
          heightFactor: 0.85,
          child: ScaffoldMessenger(
            child: _VideoTranscriptSheet(
              video: video,
              initialCaptionIndex: initialIndex,
              player: player,
              isCurrent: current,
            ),
          ),
        ),
      );
    }

    if (labeled) {
      final colors = Theme.of(context).colorScheme;
      return Tooltip(
        message: video.captions.isEmpty
            ? locals.noTranscriptTextAvailable
            : locals.transcript,
        child: FilledButton.tonalIcon(
          key: const ValueKey('video-transcript-open'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.surfaceContainerHighest,
            foregroundColor: colors.onSurface,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          onPressed: available ? open : null,
          icon: const Icon(Icons.article_outlined, size: 20),
          label: Text(locals.transcript),
        ),
      );
    }
    return IconButton(
      key: const ValueKey('video-transcript-open'),
      tooltip: locals.transcript,
      icon: const Icon(Icons.article_outlined),
      onPressed: available ? open : null,
    );
  }
}

class _VideoTranscriptSheet extends StatefulWidget {
  final Video video;
  final int initialCaptionIndex;
  final PlayerCubit player;
  final bool Function() isCurrent;

  const _VideoTranscriptSheet({
    required this.video,
    required this.initialCaptionIndex,
    required this.player,
    required this.isCurrent,
  });

  @override
  State<_VideoTranscriptSheet> createState() => _VideoTranscriptSheetState();
}

class _VideoTranscriptSheetState extends State<_VideoTranscriptSheet> {
  static const _center = ValueKey('video-transcript-center');
  // Android's clipboard sends UTF-16 text through the shared Binder buffer.
  static const _maxClipboardCodeUnits = 250000;
  static const _files = MethodChannel('videre/files');

  final _cache = <String, VideoTranscript>{};
  final _lineKeys = <int, GlobalKey>{};
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _exportMenu = MenuController();
  final _exportFocus = FocusNode();

  late final StreamSubscription<PlayerState> _playbackSubscription;
  late int _selectedCaptionIndex;
  int _requestGeneration = 0;
  int _anchor = 0;
  int? _activeIndex;
  bool _following = true;
  bool _hasPlayback = true;
  VideoTranscript? _transcript;
  bool _canCopyTranscript = false;
  List<int>? _searchResults;
  bool _loading = false;
  bool _hasError = false;
  bool _saving = false;

  bool get _canSaveFile =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Caption get _selectedCaption => widget.video.captions[_selectedCaptionIndex];
  bool get _isCurrent => _hasPlayback && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _selectedCaptionIndex = widget.initialCaptionIndex;
    _playbackSubscription =
        widget.player.stream.listen((_) => _syncActiveLine());
    _loadTranscript();
  }

  @override
  void dispose() {
    unawaited(_playbackSubscription.cancel());
    _searchFocus.dispose();
    _searchController.dispose();
    _exportFocus.dispose();
    super.dispose();
  }

  String _cacheKey(Caption caption) => caption.url.isNotEmpty
      ? caption.url
      : '${caption.languageCode ?? ''}\u0000${caption.label}';

  void _showTranscript(VideoTranscript? transcript) {
    _transcript = transcript;
    _canCopyTranscript =
        transcript?.lines.any((line) => line.text.trim().isNotEmpty) ?? false;
    _searchResults = _findMatches();
    _loading = transcript == null;
    _hasError = false;
    _activeIndex = _activeLineAtPosition();
    _anchor = _following ? _activeIndex ?? 0 : 0;
  }

  Future<void> _loadTranscript() async {
    if (!_isCurrent) return;
    final generation = ++_requestGeneration;
    final caption = _selectedCaption;
    final cached = _cache[_cacheKey(caption)];
    _lineKeys.clear();
    setState(() => _showTranscript(cached));
    if (cached != null) return;

    try {
      final transcript = await service.getTranscript(
        widget.video.videoId,
        caption,
        serverOverride: widget.video.playbackConnection?.server ??
            widget.video.backendPlayback?.server,
      );
      if (!mounted || generation != _requestGeneration || !_isCurrent) {
        return;
      }
      _cache[_cacheKey(caption)] = transcript;
      setState(() => _showTranscript(transcript));
    } catch (_) {
      if (!mounted || generation != _requestGeneration || !_isCurrent) {
        return;
      }
      setState(() {
        _loading = false;
        _hasError = true;
      });
    }
  }

  int? _activeLineAtPosition() {
    final lines = _transcript?.lines;
    if (lines == null) return null;
    final position = widget.player.state.position.inMilliseconds;
    int? active;
    var latestStart = 0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      // Transcript providers can use placeholder end times. Keep the latest
      // spoken line highlighted until the next one starts.
      if (line.type == VideoTranscriptLineType.regular &&
          line.startMs >= latestStart &&
          line.startMs <= position) {
        active = index;
        latestStart = line.startMs;
      }
    }
    return active;
  }

  void _syncActiveLine() {
    if (!_isCurrent) {
      if (_hasPlayback) {
        setState(() {
          _hasPlayback = false;
          _activeIndex = null;
          _loading = false;
        });
      }
      return;
    }
    final active = _activeLineAtPosition();
    if (active == _activeIndex) return;
    setState(() => _activeIndex = active);
    _revealActiveLine();
  }

  void _revealActiveLine() {
    if (!_following || _transcript == null) return;
    final target = _activeIndex ?? 0;
    final generation = _requestGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_isCurrent ||
          !_following ||
          generation != _requestGeneration ||
          target != (_activeIndex ?? 0)) {
        return;
      }
      final lines = _transcript?.lines;
      if (lines == null || lines.isEmpty) return;
      final row = _lineKeys[target]?.currentContext;
      if (row != null) {
        unawaited(Scrollable.ensureVisible(row, alignment: 0.24));
      } else if (_anchor != target) {
        // Start the lazy viewport at a faraway cue without laying out all the
        // intervening rows or assuming a height for wrapped captions.
        setState(() => _anchor = target);
      }
    });
  }

  void _pauseFollowing() {
    if (_following && _isCurrent) setState(() => _following = false);
  }

  void _returnToCurrent() {
    if (!_isCurrent) return;
    _searchFocus.unfocus();
    _searchController.clear();
    setState(() {
      _following = true;
      _searchResults = null;
    });
    _revealActiveLine();
  }

  Future<void> _copyTranscript({bool withTimestamps = false}) async {
    if (_loading || !_isCurrent) return;
    final text = _transcript?.toText(withTimestamps: withTimestamps) ?? '';
    if (text.isEmpty) return;

    final locals = AppLocalizations.of(context)!;
    if (_canSaveFile && text.length > _maxClipboardCodeUnits) {
      _showExportMessage(locals.transcriptTooLongToCopy);
      return;
    }

    try {
      await Clipboard.setData(ClipboardData(text: text));
      _showExportMessage(locals.transcriptCopied);
    } on Exception {
      _showExportMessage(locals.transcriptCopyFailed);
    }
  }

  Future<void> _saveTranscript() async {
    if (_saving || _loading || !_isCurrent) return;
    final text = _transcript?.toText(withTimestamps: true) ?? '';
    if (text.isEmpty) return;

    final locals = AppLocalizations.of(context)!;
    final title = _fileNamePart(widget.video.title ?? '', 42);
    final language = _fileNamePart(_selectedCaption.label, 18);
    final baseName = [
      title.isEmpty ? locals.transcript : title,
      if (language.isNotEmpty) language,
    ].join(' - ');

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() => _saving = true);
    try {
      final saved = await _files.invokeMethod<bool>('save', {
        'name': '$baseName.txt',
        'text': text,
        'mimeType': 'text/plain',
      });
      if (saved == true) _showExportMessage(locals.transcriptSaved);
    } on Exception {
      _showExportMessage(locals.transcriptSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fileNamePart(String value, int maxCharacters) {
    final safe = value
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceFirst(RegExp(r'^[.\s]+'), '');
    return String.fromCharCodes(safe.runes.take(maxCharacters)).trimRight();
  }

  void _showExportMessage(String message) {
    if (!mounted || !_isCurrent) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  List<int>? _findMatches() {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return null;
    final lines = _transcript?.lines ?? const <VideoTranscriptLine>[];
    return [
      for (final (index, line) in lines.indexed)
        if (line.text.toLowerCase().contains(query)) index,
    ];
  }

  String _formatTimestamp(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final seconds = duration.inSeconds % 60;
    final minutes = duration.inMinutes % 60;
    if (duration.inHours > 0) {
      return '${duration.inHours}:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${duration.inMinutes}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildLine(BuildContext context, VideoTranscriptLine line,
      {required int transcriptIndex, required int listIndex}) {
    final active = transcriptIndex == _activeIndex;
    final heading = line.type == VideoTranscriptLineType.heading;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return IndexedSemantics(
      index: listIndex,
      child: Semantics(
        key: _lineKeys.putIfAbsent(transcriptIndex, GlobalKey.new),
        selected: active ? true : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: active ? colors.secondaryContainer : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: EdgeInsets.only(top: heading ? 12 : 2, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton(
                  key: ValueKey('video-transcript-seek-${line.startMs}'),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        active ? colors.onSecondaryContainer : null,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(48, 36),
                  ),
                  onPressed: _isCurrent
                      ? () {
                          if (_isCurrent) {
                            widget.player
                                .seek(Duration(milliseconds: line.startMs));
                          }
                        }
                      : null,
                  onFocusChange: (focused) {
                    if (focused &&
                        FocusManager.instance.highlightMode ==
                            FocusHighlightMode.traditional) {
                      _pauseFollowing();
                    }
                  },
                  child: Text(_formatTimestamp(line.startMs)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SelectableText(
                      line.text,
                      style: heading
                          ? theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)
                          : active
                              ? TextStyle(color: colors.onSecondaryContainer)
                              : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLines(List<int>? matches) {
    final lines = _transcript!.lines;
    final count = matches?.length ?? lines.length;

    Widget buildRow(BuildContext context, int index) {
      final transcriptIndex = matches?[index] ?? index;
      return _buildLine(context, lines[transcriptIndex],
          transcriptIndex: transcriptIndex, listIndex: index);
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            (notification is ScrollStartNotification &&
                    notification.dragDetails != null ||
                notification is UserScrollNotification &&
                    notification.direction != ScrollDirection.idle)) {
          _pauseFollowing();
        }
        return false;
      },
      child: KeyedSubtree(
        key: const ValueKey('video-transcript-list'),
        child: CustomScrollView(
          key: ValueKey((_requestGeneration, _anchor, _searchController.text)),
          primary: false,
          center: _center,
          semanticChildCount: count,
          slivers: [
            if (_anchor > 0)
              SliverList.builder(
                addSemanticIndexes: false,
                itemCount: _anchor,
                itemBuilder: (context, index) =>
                    buildRow(context, _anchor - index - 1),
              ),
            SliverList.builder(
              key: _center,
              addSemanticIndexes: false,
              itemCount: count - _anchor,
              itemBuilder: (context, index) =>
                  buildRow(context, _anchor + index),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final canExport = _isCurrent && !_loading && _canCopyTranscript;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  locals.transcript,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                key: const ValueKey('video-transcript-copy'),
                tooltip: locals.copyTranscript,
                onPressed: canExport ? _copyTranscript : null,
                icon: const Icon(Icons.copy_all_outlined),
              ),
              MenuAnchor(
                controller: _exportMenu,
                childFocusNode: _exportFocus,
                consumeOutsideTap: true,
                crossAxisUnconstrained: false,
                menuChildren: [
                  MenuItemButton(
                    key: const ValueKey('video-transcript-copy-timed'),
                    autofocus: true,
                    leadingIcon: const Icon(Icons.schedule),
                    onPressed: canExport
                        ? () => _copyTranscript(withTimestamps: true)
                        : null,
                    child: Text(locals.copyTranscriptWithTimestamps),
                  ),
                  if (_canSaveFile)
                    MenuItemButton(
                      key: const ValueKey('video-transcript-save'),
                      leadingIcon: const Icon(Icons.save_alt),
                      onPressed: canExport && !_saving ? _saveTranscript : null,
                      child: Text(locals.saveTranscriptAsText),
                    ),
                ],
                builder: (context, controller, child) => IconButton(
                  key: const ValueKey('video-transcript-export'),
                  focusNode: _exportFocus,
                  tooltip: locals.transcriptExportActions,
                  onPressed: canExport
                      ? (controller.isOpen ? controller.close : controller.open)
                      : null,
                  icon: const Icon(Icons.more_vert),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: const ValueKey('video-transcript-language'),
            initialValue: _selectedCaptionIndex,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              for (var index = 0; index < widget.video.captions.length; index++)
                DropdownMenuItem(
                  value: index,
                  child: Text(widget.video.captions[index].label),
                ),
            ],
            onChanged: !_isCurrent || widget.video.captions.length == 1
                ? null
                : (index) {
                    if (index == null ||
                        index == _selectedCaptionIndex ||
                        !_isCurrent) {
                      return;
                    }
                    _selectedCaptionIndex = index;
                    _loadTranscript();
                  },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('video-transcript-search'),
            controller: _searchController,
            focusNode: _searchFocus,
            onTap: _pauseFollowing,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: locals.searchTranscript,
              isDense: true,
            ),
            onChanged: (_) => setState(() {
              _following = false;
              _anchor = 0;
              _searchResults = _findMatches();
            }),
          ),
          if (!_following &&
              _isCurrent &&
              (_transcript?.lines.isNotEmpty ?? false))
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: _returnToCurrent,
                icon: const Icon(Icons.my_location),
                label: Text(locals.returnToCurrentTranscriptLine),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(
                    child: MotionLoadingIndicator(
                        child: CircularProgressIndicator()))
                : _hasError
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.subtitles_off),
                            const SizedBox(height: 8),
                            Text(locals.couldntLoadTranscript),
                            const SizedBox(height: 8),
                            FilledButton.tonal(
                              key: const ValueKey('video-transcript-retry'),
                              onPressed: _loadTranscript,
                              child: Text(locals.retry),
                            ),
                          ],
                        ),
                      )
                    : _transcript == null || _transcript!.lines.isEmpty
                        ? Center(child: Text(locals.noTranscriptTextAvailable))
                        : _buildLines(_searchResults),
          ),
        ],
      ),
    );

    return PlayerModalBackHandler(
      onBack: () {
        if (_exportMenu.isOpen) {
          _exportMenu.close();
          _exportFocus.requestFocus();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: content,
      ),
    );
  }
}
