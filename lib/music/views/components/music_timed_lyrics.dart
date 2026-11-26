import 'dart:async';
import 'dart:io';

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_current_cue.dart';
import 'package:clipious/music/models/music_lyrics.dart';
import 'package:clipious/music/services/music_lyrics_reader_preferences.dart';
import 'package:clipious/player/states/player.dart';
import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_lyric_share_button.dart';
import 'music_lyric_cue_details.dart';
import 'music_word_timed_lyric_line.dart';

class MusicTimedLyrics extends StatefulWidget {
  final MusicLyrics lyrics;
  final MusicMetadata track;
  final bool edited;
  final MusicLyricsReaderPreferences preferences;
  final Duration seekLimit;
  final Duration delay;
  final bool Function() isCurrent;
  final ValueChanged<Duration> onSeek;
  final Future<List<File>> Function()? loadShareArtwork;

  const MusicTimedLyrics({
    super.key,
    required this.lyrics,
    required this.track,
    required this.edited,
    required this.preferences,
    required this.seekLimit,
    required this.delay,
    required this.isCurrent,
    required this.onSeek,
    this.loadShareArtwork,
  });

  @override
  State<MusicTimedLyrics> createState() => _MusicTimedLyricsState();
}

class _MusicTimedLyricsState extends State<MusicTimedLyrics> {
  static const _center = ValueKey('music-lyrics-current-section');
  static const _followDelay = Duration(seconds: 5);
  static const _alignment = 0.32;
  final _lineKeys = <int, GlobalKey>{};
  final _selectedLines = <int>{};
  late int _anchor;
  int? _lastRevealed;
  bool _followEnabled = true;
  bool _browsing = false;
  bool _scrolling = false;
  bool _selecting = false;
  int? _focusedRow;
  Timer? _followTimer;
  Duration? _previewPosition;
  int _sliderRevision = 0;
  ModalRoute<dynamic>? _route;
  Orientation? _orientation;

  List<MusicLyricCue> get _cues => widget.lyrics.cues;
  bool get _following => _followEnabled && !_browsing;
  bool get _canSeek =>
      mounted && _route?.isCurrent != false && widget.isCurrent();

  @override
  void initState() {
    super.initState();
    _anchor = _startingAnchor();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final orientation = MediaQuery.orientationOf(context);
    if (_route?.isCurrent == false ||
        (_orientation != null && _orientation != orientation)) {
      _retireSlider();
    }
    _orientation = orientation;
  }

  @override
  void didUpdateWidget(covariant MusicTimedLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lyrics, widget.lyrics)) {
      _lineKeys.clear();
      _selectedLines.clear();
      _selecting = false;
      _focusedRow = null;
      _anchor = _startingAnchor();
      _resumeFollowing();
      _retireSlider();
    } else if (oldWidget.seekLimit != widget.seekLimit) {
      _retireSlider();
    }
  }

  @override
  void dispose() {
    _followTimer?.cancel();
    super.dispose();
  }

  int _startingAnchor() {
    final position = context.read<PlayerCubit>().state.position;
    final active = activeMusicLyricIndex(_cues, position - widget.delay);
    return active < 0 ? 0 : active;
  }

  bool get _canReveal =>
      !_selecting && _canSeek && (_following || _previewPosition != null);

  void _reveal(int active, {required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_canReveal || _lastRevealed != active) return;
      final target = active < 0 ? 0 : active;
      final row = _lineKeys[target]?.currentContext;
      if (row != null) {
        unawaited(Scrollable.ensureVisible(row,
            alignment: _alignment,
            duration: animate ? AppMotion.duration(row) : Duration.zero,
            curve: Curves.easeInOut));
      } else if (_anchor != target) {
        // Recenter the lazy viewport for a seek across many unbuilt rows.
        setState(() {
          _anchor = target;
          _lastRevealed = null;
        });
      }
    });
  }

  void _pauseForBrowsing() {
    if (_selecting) return;
    _followTimer?.cancel();
    if (_followEnabled && !_browsing) setState(() => _browsing = true);
  }

  void _scheduleFollow() {
    _followTimer?.cancel();
    if (_selecting || !_browsing || _scrolling || _focusedRow != null) return;
    _followTimer = Timer(_followDelay, () => setState(_resumeFollowing));
  }

  void _resumeFollowing() {
    _followTimer?.cancel();
    _browsing = false;
    _scrolling = false;
    _lastRevealed = null;
  }

  bool _scrollNotification(ScrollNotification notice) {
    if (_selecting || notice.depth != 0) return false;
    if ((notice is ScrollStartNotification && notice.dragDetails != null) ||
        (notice is UserScrollNotification &&
            notice.direction != ScrollDirection.idle)) {
      _scrolling = true;
      _pauseForBrowsing();
    } else if (notice is ScrollEndNotification && _scrolling) {
      _scrolling = false;
      _scheduleFollow();
    }
    return false;
  }

  void _rowFocusChanged(int index, bool focused) {
    if (!mounted) return;
    if (focused) {
      _focusedRow = index;
      _pauseForBrowsing();
    } else if (_focusedRow == index) {
      _focusedRow = null;
      _scheduleFollow();
    }
  }

  void _retireSlider() {
    _previewPosition = null;
    _lastRevealed = null;
    _sliderRevision++;
  }

  void _seek(Duration position) {
    if (_canSeek && position >= Duration.zero && position <= widget.seekLimit) {
      widget.onSeek(position);
    }
  }

  void _setSelecting(bool selecting) {
    setState(() {
      _selecting = selecting;
      _selectedLines.clear();
      _scrolling = false;
      _retireSlider();
    });
    _scheduleFollow();
  }

  void _toggleLine(int index) {
    if (!_canSeek) return;
    setState(() {
      if (!_selectedLines.add(index)) _selectedLines.remove(index);
    });
  }

  Widget _line(BuildContext context, int index, int active, Duration position) {
    final cue = _cues[index];
    final start = cue.start + widget.delay;
    final seekPosition = start < Duration.zero ? Duration.zero : start;
    final metadata = widget.lyrics.metadataByCue[index];
    final playing = switch (metadata?.end) {
      final end? => cue.start <= position && position < end,
      null => active >= 0 && cue.start == _cues[active].start,
    };
    final selected = _selectedLines.contains(index);
    final canSelect = cue.text.trim().isNotEmpty;
    final words = widget.lyrics.wordsByCue[index];
    final text = widget.preferences.syncedCueText(widget.lyrics, index);
    final alignment =
        widget.preferences.alignment == MusicLyricsTextAlignment.center
            ? TextAlign.center
            : TextAlign.start;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = playing && words != null
        ? MusicWordTimedLyricLine(
            text: text,
            words: words,
            position: position,
            wordOffset: (text.length - text.trimLeft().length) -
                (cue.text.length - cue.text.trimLeft().length),
            textAlign: alignment)
        : Text(text, textAlign: alignment);
    return IndexedSemantics(
      index: index,
      child: ListTile(
        key: _lineKeys.putIfAbsent(index, GlobalKey.new),
        selected: _selecting ? selected : playing,
        selectedColor: colors.onSecondaryContainer,
        selectedTileColor: colors.secondaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
            fontSize: widget.preferences.size.fontSize,
            fontWeight: playing ? FontWeight.w700 : null),
        leading: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: AppMotion.fadeDuration(
                context, const Duration(milliseconds: 180)),
            width: 4,
            height: 24,
            decoration: BoxDecoration(
                color: playing ? colors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 8),
          Text(prettyDurationCustom(seekPosition)),
        ]),
        title: metadata != null && metadata.hasDetails
            ? MusicLyricCueDetails(
                metadata: metadata, alignment: alignment, child: title)
            : title,
        trailing: _selecting && canSelect
            ? Icon(selected ? Icons.check_circle : Icons.circle_outlined)
            : null,
        onFocusChange: (focused) => _rowFocusChanged(index, focused),
        onTap: _selecting
            ? (canSelect ? () => _toggleLine(index) : null)
            : seekPosition <= widget.seekLimit
                ? () => _seek(seekPosition)
                : null,
      ),
    );
  }

  Widget _seekControls(Duration position, int active) {
    final locals = AppLocalizations.of(context)!;
    final max = widget.seekLimit.inMilliseconds.toDouble();
    final revision = _sliderRevision;
    final time = prettyDurationCustom(position);
    bool canUseSlider() => _canSeek && revision == _sliderRevision;

    void preview(double value) {
      if (!canUseSlider()) return;
      setState(() => _previewPosition = Duration(milliseconds: value.round()));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_previewPosition != null)
          Text(
            active < 0
                ? time
                : '$time · ${widget.preferences.syncedCueText(widget.lyrics, active)}',
            key: const ValueKey('music-lyrics-seek-preview'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        Row(children: [
          Expanded(
            child: Listener(
              key: ValueKey(revision),
              onPointerCancel: (_) {
                if (canUseSlider()) setState(_retireSlider);
              },
              child: Semantics(
                label: locals.musicPosition,
                child: Slider(
                  key: const ValueKey('music-lyrics-position'),
                  value: position.inMilliseconds.toDouble().clamp(0.0, max),
                  max: max,
                  semanticFormatterCallback: (value) => prettyDurationCustom(
                      Duration(milliseconds: value.round())),
                  onChangeStart: preview,
                  onChanged: preview,
                  onChangeEnd: (value) {
                    if (!canUseSlider() || _previewPosition == null) return;
                    _seek(Duration(milliseconds: value.round()));
                    setState(() {
                      _previewPosition = null;
                      _lastRevealed = null;
                    });
                  },
                ),
              ),
            ),
          ),
          FilterChip(
            label: Text(locals.musicFollowLyrics),
            selected: _following,
            onSelected: (following) => setState(() {
              _followEnabled = following;
              _resumeFollowing();
            }),
          ),
        ]),
      ],
    );
  }

  Widget _selectionControls(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final lyrics = widget.lyrics;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          FilterChip(
            label: Text(locals.musicLyricsSelectLines),
            selected: _selecting,
            onSelected: _setSelecting,
          ),
          if (_selecting)
            MusicLyricShareButton(
              lines: [
                for (final index in _selectedLines.toList()..sort())
                  _cues[index].text,
              ],
              track: widget.track,
              source: lyrics.source,
              edited: widget.edited,
              loadArtwork: widget.loadShareArtwork,
              isCurrent: () =>
                  mounted &&
                  identical(widget.lyrics, lyrics) &&
                  widget.isCurrent(),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playbackPosition =
        context.select((PlayerCubit player) => player.state.position);
    final position = _previewPosition ?? playbackPosition;
    // Compare in lyric time. The slider and its seek stay in playback time.
    final lyricPosition = position - widget.delay;
    final active = activeMusicLyricIndex(_cues, lyricPosition);
    if (_canReveal && _lastRevealed != active) {
      final animate = _lastRevealed != null && _previewPosition == null;
      _lastRevealed = active;
      _reveal(active, animate: animate);
    }
    return Column(children: [
      Expanded(
        child: NotificationListener<ScrollNotification>(
          onNotification: _scrollNotification,
          child: KeyedSubtree(
            key: const ValueKey('music-lyrics-lines'),
            child: CustomScrollView(
              key: ValueKey((widget.lyrics, _anchor)),
              primary: false,
              center: _center,
              semanticChildCount: _cues.length,
              slivers: [
                if (_anchor > 0)
                  SliverList.builder(
                    addSemanticIndexes: false,
                    itemCount: _anchor,
                    itemBuilder: (context, index) => _line(
                        context, _anchor - index - 1, active, lyricPosition),
                  ),
                SliverList.builder(
                  key: _center,
                  addSemanticIndexes: false,
                  itemCount: _cues.length - _anchor,
                  itemBuilder: (context, index) =>
                      _line(context, _anchor + index, active, lyricPosition),
                ),
              ],
            ),
          ),
        ),
      ),
      if (!_selecting) _seekControls(position, active),
      _selectionControls(context),
    ]);
  }
}
