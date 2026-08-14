import 'package:clipious/globals.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/settings/states/settings.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/videos/models/caption.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:clipious/videos/models/video_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class VideoTranscriptButton extends StatelessWidget {
  final Video video;

  const VideoTranscriptButton({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return IconButton(
      key: const ValueKey('video-transcript-open'),
      tooltip: locals.transcript,
      icon: const Icon(Icons.article_outlined),
      onPressed: () {
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
            child: _VideoTranscriptSheet(
              video: video,
              initialCaptionIndex: initialIndex,
            ),
          ),
        );
      },
    );
  }
}

class _VideoTranscriptSheet extends StatefulWidget {
  final Video video;
  final int initialCaptionIndex;

  const _VideoTranscriptSheet({
    required this.video,
    required this.initialCaptionIndex,
  });

  @override
  State<_VideoTranscriptSheet> createState() => _VideoTranscriptSheetState();
}

class _VideoTranscriptSheetState extends State<_VideoTranscriptSheet> {
  final _cache = <String, VideoTranscript>{};
  final _searchController = TextEditingController();

  late int _selectedCaptionIndex;
  int _requestGeneration = 0;
  VideoTranscript? _transcript;
  bool _loading = true;
  bool _hasError = false;

  Caption get _selectedCaption => widget.video.captions[_selectedCaptionIndex];

  @override
  void initState() {
    super.initState();
    _selectedCaptionIndex = widget.initialCaptionIndex;
    _loadTranscript();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _cacheKey(Caption caption) => caption.url.isNotEmpty
      ? caption.url
      : '${caption.languageCode ?? ''}\u0000${caption.label}';

  Future<void> _loadTranscript() async {
    final generation = ++_requestGeneration;
    final caption = _selectedCaption;
    final cached = _cache[_cacheKey(caption)];
    if (cached != null) {
      setState(() {
        _transcript = cached;
        _loading = false;
        _hasError = false;
      });
      return;
    }

    setState(() {
      _transcript = null;
      _loading = true;
      _hasError = false;
    });

    try {
      final transcript =
          await service.getTranscript(widget.video.videoId, caption);
      if (!mounted || generation != _requestGeneration) return;
      _cache[_cacheKey(caption)] = transcript;
      setState(() {
        _transcript = transcript;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _loading = false;
        _hasError = true;
      });
    }
  }

  Future<void> _copyTranscript() async {
    final text = _transcript?.plainText ?? '';
    if (_loading || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.transcriptCopied)),
    );
  }

  List<VideoTranscriptLine> get _displayedLines {
    final lines = _transcript?.lines ?? const <VideoTranscriptLine>[];
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return lines;
    return lines
        .where((line) => line.text.toLowerCase().contains(query))
        .toList();
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

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final transcriptText = _transcript?.plainText ?? '';
    final lines = _displayedLines;

    return Padding(
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
              FilledButton.tonalIcon(
                key: const ValueKey('video-transcript-copy'),
                onPressed:
                    _loading || transcriptText.isEmpty ? null : _copyTranscript,
                icon: const Icon(Icons.copy_all_outlined),
                label: Text(locals.copyTranscript),
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
            onChanged: widget.video.captions.length == 1
                ? null
                : (index) {
                    if (index == null || index == _selectedCaptionIndex) return;
                    setState(() => _selectedCaptionIndex = index);
                    _loadTranscript();
                  },
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('video-transcript-search'),
            controller: _searchController,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: locals.searchTranscript,
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
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
                        : ListView.builder(
                            key: const ValueKey('video-transcript-list'),
                            itemCount: lines.length,
                            itemBuilder: (context, index) {
                              final line = lines[index];
                              final isHeading =
                                  line.type == VideoTranscriptLineType.heading;
                              return Padding(
                                padding: EdgeInsets.only(
                                  top: isHeading ? 12 : 2,
                                  bottom: 2,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextButton(
                                      key: ValueKey(
                                        'video-transcript-seek-${line.startMs}',
                                      ),
                                      style: TextButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        minimumSize: const Size(48, 36),
                                      ),
                                      onPressed: () =>
                                          context.read<PlayerCubit>().seek(
                                                Duration(
                                                  milliseconds: line.startMs,
                                                ),
                                              ),
                                      child: Text(
                                        _formatTimestamp(line.startMs),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: SelectableText(
                                          line.text,
                                          style: isHeading
                                              ? Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  )
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
