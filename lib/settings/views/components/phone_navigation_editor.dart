import 'package:clipious/utils/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../home/models/phone_navigation.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../states/settings.dart';
import 'home_experience_setting.dart';

enum _ItemAction { bottom, top, hidden, earlier, later, startup }

typedef _DropLocation = ({NavigationArea area, PhoneNavigationItem? before});

class PhoneNavigationEditor extends StatefulWidget {
  const PhoneNavigationEditor({super.key});

  @override
  State<PhoneNavigationEditor> createState() => _PhoneNavigationEditorState();
}

class _PhoneNavigationEditorState extends State<PhoneNavigationEditor> {
  bool _saving = false;
  EdgeDraggingAutoScroller? _dragScroller;
  Offset? _dragPosition;
  PhoneNavigationItem? _draggingItem;
  _DropLocation? _dropLocation;
  final _viewportKey = GlobalKey();
  final _areaKeys = {
    for (final area in NavigationArea.values) area: GlobalKey()
  };
  final _itemKeys = {
    for (final item in PhoneNavigationItem.values) item: GlobalKey()
  };

  Rect? _bounds(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
  }

  _DropLocation? _locationAt(Offset position) {
    if (!(_bounds(_viewportKey)?.contains(position) ?? false)) return null;
    final layout = context.read<SettingsCubit>().state.phoneNavigation;
    for (final area in NavigationArea.values) {
      if (!(_bounds(_areaKeys[area]!)?.contains(position) ?? false)) continue;
      for (final item in layout.items(area)) {
        if (_bounds(_itemKeys[item]!)?.contains(position) ?? false) {
          return (area: area, before: item);
        }
      }
      return (area: area, before: null);
    }
    return null;
  }

  void _acceptDrop(DragTargetDetails<PhoneNavigationItem> details) {
    // Scrolling can change the item under a stationary finger. Resolve the
    // current geometry at release instead of a DragTarget cached before scroll.
    final location = _locationAt(details.offset);
    if (location == null || location.before == details.data) return;
    final layout = context.read<SettingsCubit>().state.phoneNavigation;
    final moved =
        layout.move(details.data, location.area, before: location.before);
    if (moved?.encode() != layout.encode()) _save(moved);
  }

  void _continueDragScroll() {
    final position = _dragPosition;
    if (position != null && mounted) {
      final location = _locationAt(position);
      if (location != _dropLocation) setState(() => _dropLocation = location);
      _dragScroller?.startAutoScrollIfNecessary(
          Rect.fromCenter(center: position, width: 48, height: 64));
    }
  }

  void _stopDragScroll() {
    _dragScroller?.stopAutoScroll();
    _dragScroller = null;
    _dragPosition = null;
  }

  void _endDrag() {
    _stopDragScroll();
    if (mounted) {
      setState(() {
        _draggingItem = null;
        _dropLocation = null;
      });
    }
  }

  @override
  void dispose() {
    _stopDragScroll();
    super.dispose();
  }

  Future<void> _save(PhoneNavigation? layout) async {
    if (_saving) return;
    final locals = AppLocalizations.of(context)!;
    if (layout == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(locals.phoneNavigationLimit)));
      return;
    }
    setState(() => _saving = true);
    try {
      await context.read<SettingsCubit>().setPhoneNavigation(layout);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(locals.phoneNavigationSaveError)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _areaLabel(NavigationArea area, AppLocalizations locals) =>
      switch (area) {
        NavigationArea.bottom => locals.phoneNavigationBottom,
        NavigationArea.top => locals.phoneNavigationTop,
        NavigationArea.hidden => locals.phoneNavigationHidden,
      };

  Widget _item(
      PhoneNavigation layout, NavigationArea area, PhoneNavigationItem item) {
    final locals = AppLocalizations.of(context)!;
    final items = layout.items(area);
    final index = items.indexOf(item);
    final chip = PopupMenuButton<_ItemAction>(
      key: ValueKey('navigation-item-${item.name}'),
      // A Tooltip's own long-press recognizer would win against dragging.
      tooltip: '',
      onSelected: (action) {
        switch (action) {
          case _ItemAction.startup:
            _save(layout.startAt(item));
          case _ItemAction.earlier:
            _save(layout.move(item, area, before: items[index - 1]));
          case _ItemAction.later:
            _save(layout.move(item, area,
                before: items.elementAtOrNull(index + 2)));
          case _ItemAction.bottom:
            _save(layout.move(item, NavigationArea.bottom));
          case _ItemAction.top:
            _save(layout.move(item, NavigationArea.top));
          case _ItemAction.hidden:
            _save(layout.move(item, NavigationArea.hidden));
        }
      },
      itemBuilder: (_) => [
        for (final destination in NavigationArea.values)
          if (destination != area)
            PopupMenuItem(
                value: _ItemAction.values[destination.index],
                child: Text(_areaLabel(destination, locals))),
        if (area != NavigationArea.hidden && index > 0)
          PopupMenuItem(
              value: _ItemAction.earlier,
              child: Text(locals.phoneNavigationEarlier)),
        if (area != NavigationArea.hidden && index < items.length - 1)
          PopupMenuItem(
              value: _ItemAction.later,
              child: Text(locals.phoneNavigationLater)),
        if (area == NavigationArea.bottom && item.isTab)
          PopupMenuItem(
              value: _ItemAction.startup,
              child: Text(locals.phoneNavigationStartup)),
      ],
      child: Chip(
        avatar: Icon(item.icon, size: 20),
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(item.label(locals), overflow: TextOverflow.ellipsis)),
          if (layout.startup == item) ...[
            const SizedBox(width: 4),
            Icon(Icons.star,
                size: 14, semanticLabel: locals.phoneNavigationStartup),
          ],
        ]),
      ),
    );
    return Builder(
        builder: (context) => DecoratedBox(
              key: _itemKeys[item],
              decoration: BoxDecoration(
                  border: _dropLocation?.before != item || _draggingItem == item
                      ? null
                      : Border(
                          left: BorderSide(
                              width: 3,
                              color: Theme.of(context).colorScheme.primary))),
              child: LongPressDraggable<PhoneNavigationItem>(
                data: item,
                maxSimultaneousDrags: _saving || _draggingItem != null ? 0 : 1,
                dragAnchorStrategy: (_, __, position) {
                  _dragPosition = position;
                  return Offset.zero;
                },
                onDragStarted: () => setState(() => _draggingItem = item),
                onDragUpdate: (details) {
                  _dragPosition = details.globalPosition;
                  _dragScroller ??= EdgeDraggingAutoScroller(
                      Scrollable.of(context),
                      velocityScalar: 24,
                      onScrollViewScrolled: _continueDragScroll);
                  _continueDragScroll();
                },
                onDragEnd: (_) => _endDrag(),
                feedback: Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(24),
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(item.label(locals)))),
                childWhenDragging: Opacity(opacity: 0.3, child: chip),
                child: chip,
              ),
            ));
  }

  @override
  Widget build(BuildContext context) {
    final layout = context.watch<SettingsCubit>().state.phoneNavigation;
    final locals = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: _saving,
      child: DragTarget<PhoneNavigationItem>(
          onWillAcceptWithDetails: (_) => !_saving,
          onAcceptWithDetails: _acceptDrop,
          builder: (context, candidates, rejected) => SingleChildScrollView(
              key: _viewportKey,
              padding: const EdgeInsets.all(16),
              // There are only ten items. Keep the dragged source mounted even
              // when scrolling it offscreen so it still receives update/end events.
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const HomeExperienceSetting(),
                    const SizedBox(height: 12),
                    Text(locals.phoneNavigationHelp),
                    if (_saving)
                      const MotionLoadingIndicator(
                          child: LinearProgressIndicator()),
                    for (final area in [
                      NavigationArea.top,
                      NavigationArea.bottom,
                      NavigationArea.hidden
                    ])
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: KeyedSubtree(
                            key: _areaKeys[area],
                            child: Container(
                              key: ValueKey('navigation-area-${area.name}'),
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: _dropLocation?.area != area
                                      ? colors.surfaceContainerLow
                                      : colors.secondaryContainer,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                      color: _dropLocation?.area != area
                                          ? colors.outlineVariant
                                          : colors.primary)),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_areaLabel(area, locals),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall),
                                    Wrap(spacing: 8, children: [
                                      for (final item in layout.items(area))
                                        _item(layout, area, item)
                                    ]),
                                    SizedBox(
                                        height: 32,
                                        child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                                locals.phoneNavigationDrop,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall))),
                                  ]),
                            ),
                          )),
                    const SizedBox(height: 12),
                    Text(locals.phoneNavigationLimit,
                        style: Theme.of(context).textTheme.bodySmall),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                            onPressed: () => _save(PhoneNavigation.defaults()),
                            icon: const Icon(Icons.restore),
                            label: Text(locals.phoneNavigationReset))),
                  ]))),
    );
  }
}
