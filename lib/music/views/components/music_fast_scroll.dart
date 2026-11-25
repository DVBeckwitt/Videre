import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/music_fast_scroll_sections.dart';

/// Builds section labels from the primary values of the current display sort.
/// A collection in source order can omit [sortValue] to show position ranges.
/// Numeric duration keys are seconds. A [Duration] can carry finer precision,
/// and a `(bytes: value)` record identifies a file size key.
List<MusicFastScrollSection> musicFastScrollSectionsFor<T>(
  BuildContext context,
  List<T> rows, {
  Object? Function(T row)? sortValue,
}) {
  final labels = AppLocalizations.of(context)!;
  final material = MaterialLocalizations.of(context);
  String durationLabel(int seconds) => seconds >= 3600
      ? labels.musicFastScrollLongDuration
      : labels.musicFastScrollDurationRange(
          material.formatDecimal(seconds ~/ 300 * 5),
          material.formatDecimal(seconds ~/ 300 * 5 + 4),
        );
  String sizeLabel(int bytes) {
    final band = bytes ~/ (10 * 1024 * 1024) * 10;
    return band >= 100
        ? labels.musicFastScrollLargeSize
        : labels.musicFastScrollSizeRange(
            material.formatDecimal(band), material.formatDecimal(band + 9));
  }

  String? sectionLabel(T row) {
    final value = sortValue!(row);
    return switch (value) {
      String text => musicFastScrollInitial(text),
      DateTime date => material.formatYear(date.toLocal()),
      int seconds when seconds > 0 => durationLabel(seconds),
      Duration duration => durationLabel(duration.inSeconds),
      (bytes: final int bytes) => sizeLabel(bytes),
      _ => null,
    };
  }

  return musicFastScrollSections(
    rows,
    rangeLabel: (first, last) => labels.musicFastScrollPositions(
      material.formatDecimal(first),
      material.formatDecimal(last),
    ),
    sectionLabel: sortValue == null ? null : sectionLabel,
    unknownLabel: labels.musicFastScrollUnknown,
  );
}

/// Adds a focusable section picker to an existing scroll view with lazy rows.
/// [scope] identifies the active collection, sort and filters. [leadingItems]
/// counts non-collection children in the same sliver as the displayed rows.
class MusicFastScroll extends StatefulWidget {
  const MusicFastScroll({
    super.key,
    required this.sections,
    required this.scope,
    required this.child,
    this.leadingItems = 0,
  });

  final List<MusicFastScrollSection> sections;
  final Object scope;
  final Widget child;
  final int leadingItems;

  @override
  State<MusicFastScroll> createState() => _MusicFastScrollState();
}

class _MusicFastScrollState extends State<MusicFastScroll> {
  final _scrollView = GlobalKey();
  int _request = 0;

  @override
  void didUpdateWidget(covariant MusicFastScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scope != oldWidget.scope ||
        widget.leadingItems != oldWidget.leadingItems ||
        !listEquals(widget.sections, oldWidget.sections)) {
      _request++;
    }
  }

  Future<void> _chooseSection() async {
    final request = ++_request;
    final sections = widget.sections;
    final label = AppLocalizations.of(context)!.musicFastScrollJumpTo;
    final choice = await showDialog<MusicFastScrollSection>(
      context: context,
      requestFocus: true,
      builder: (context) => Shortcuts(
        shortcuts: _selectShortcuts,
        child: SimpleDialog(
          title: Text(label),
          children: [
            SizedBox(
              width: 280,
              height: math.min(
                MediaQuery.sizeOf(context).height * .55,
                56.0 * sections.length,
              ),
              child: ListView.builder(
                primary: false,
                padding: EdgeInsets.zero,
                itemCount: sections.length,
                itemBuilder: (_, index) {
                  final section = sections[index];
                  return ListTile(
                    autofocus: index == 0,
                    title: Text(section.label),
                    onTap: () => Navigator.of(context).pop(section),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted && request == _request && choice != null) {
      await _reveal(choice.index + widget.leadingItems, request);
    }
  }

  Future<void> _reveal(int index, int request) async {
    double? lower;
    double? upper;
    for (var attempt = 0; attempt < 16; attempt++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || request != _request) return;

      final viewport =
          _findViewport(_scrollView.currentContext?.findRenderObject());
      final sliver = _findRows(viewport);
      final position = viewport?.offset;
      final first = sliver?.firstChild;
      final last = sliver?.lastChild;
      if (position is! ScrollPosition ||
          !position.hasContentDimensions ||
          sliver == null ||
          first == null ||
          last == null) {
        return;
      }
      final firstIndex = sliver.indexOf(first);
      final lastIndex = sliver.indexOf(last);
      if (firstIndex <= index && index <= lastIndex) {
        var child = first;
        while (sliver.indexOf(child) < index) {
          child = sliver.childAfter(child)!;
        }
        unawaited(position.ensureVisible(child));
        return;
      }

      // Variable-height slivers estimate offsets beyond the laid-out rows.
      // Seek using the current layout, then reveal the exact row once built.
      final pixels = position.pixels;
      final firstOffset = sliver.childScrollOffset(first)!;
      final lastOffset = sliver.childScrollOffset(last)!;
      final averageExtent = (lastOffset - firstOffset + last.size.height) /
          (lastIndex - firstIndex + 1);
      final before = index < firstIndex;
      final at = before ? firstIndex : lastIndex;
      final offset = before ? firstOffset : lastOffset;
      var next = sliver.constraints.precedingScrollExtent +
          offset +
          (index - at) * averageExtent;
      if (before) {
        upper = pixels;
        if (next >= pixels) next = pixels - position.viewportDimension;
      } else {
        lower = pixels;
        if (next <= pixels) next = pixels + position.viewportDimension;
      }
      if (lower != null && upper != null && (next <= lower || next >= upper)) {
        next = (lower + upper) / 2;
      }
      next = next
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if (next == pixels) return;
      position.jumpTo(next);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (widget.sections.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Shortcuts(
              shortcuts: _selectShortcuts,
              child: TextButton.icon(
                key: const ValueKey('music-fast-scroll'),
                icon: const Icon(Icons.swap_vert),
                label:
                    Text(AppLocalizations.of(context)!.musicFastScrollJumpTo),
                onPressed: _chooseSection,
              ),
            ),
          ),
        Expanded(
          key: const ValueKey('music-fast-scroll-viewport'),
          child: Listener(
            onPointerDown: (_) => _request++,
            onPointerSignal: (_) => _request++,
            child: KeyedSubtree(key: _scrollView, child: widget.child),
          ),
        ),
      ]);
}

final _selectShortcuts = {
  for (final key in selectKeys) SingleActivator(key): const ActivateIntent(),
};

RenderViewport? _findViewport(RenderObject? root) {
  if (root is RenderViewport) return root;
  RenderViewport? viewport;
  root?.visitChildren((child) => viewport ??= _findViewport(child));
  return viewport;
}

RenderSliverMultiBoxAdaptor? _findRows(RenderObject? root) {
  if (root is RenderSliverMultiBoxAdaptor) return root;
  RenderSliverMultiBoxAdaptor? rows;
  if (root is RenderViewport || root is RenderSliverPadding) {
    root!.visitChildren((child) => rows ??= _findRows(child));
  }
  return rows;
}
