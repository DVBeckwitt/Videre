import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../settings/states/settings.dart';
import '../../models/music_layout.dart';
import '../components/local_music_folder.dart';

class MusicLayoutEditor extends StatefulWidget {
  final bool includeSearchShortcut;
  final bool libraryCategoriesOnly;

  const MusicLayoutEditor({
    super.key,
    this.includeSearchShortcut = false,
    this.libraryCategoriesOnly = false,
  });

  static Future<void> open(
    BuildContext context, {
    bool includeSearchShortcut = false,
    bool libraryCategoriesOnly = false,
  }) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => MusicLayoutEditor(
                includeSearchShortcut: includeSearchShortcut,
                libraryCategoriesOnly: libraryCategoriesOnly,
              )));

  @override
  State<MusicLayoutEditor> createState() => _MusicLayoutEditorState();
}

class _MusicLayoutEditorState extends State<MusicLayoutEditor> {
  late final String _profile;
  late final int _session;
  int _editRevision = 0;
  MusicLayout? _pending;

  @override
  void initState() {
    super.initState();
    _profile = db.profileId;
    _session = context.read<AppCubit>().state.sessionRevision;
  }

  bool _current(AppState state) =>
      db.profileId == _profile &&
      state.sessionRevision == _session &&
      !state.globalLoading &&
      !state.sessionRecoveryRequired;

  Future<void> _save(MusicLayout Function(MusicLayout) update) async {
    if (!_current(context.read<AppCubit>().state)) return;
    final settings = context.read<SettingsCubit>();
    final revision = ++_editRevision;
    // Writes run in order. Keep the latest edit interactive while the database
    // catches up, including when moving several buttons with a TV remote.
    setState(() => _pending = update(_pending ?? settings.state.musicLayout));
    try {
      await settings.updateMusicLayout(update);
    } on Object {
      if (mounted &&
          revision == _editRevision &&
          _current(context.read<AppCubit>().state)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.phoneNavigationSaveError)));
      }
    } finally {
      if (mounted && revision == _editRevision) {
        setState(() => _pending = null);
      }
    }
  }

  bool _shortcutAvailable(MusicShortcut item) =>
      widget.includeSearchShortcut || item != MusicShortcut.search;

  bool _categoryAvailable(MusicLibraryCategory item) =>
      item.isAvailable(tv: isTv, deviceFolders: supportsLocalMusicFolders);

  List<T> _reorderAvailable<T>(
      List<T> current, List<T> reordered, bool Function(T) available) {
    var index = 0;
    return [
      for (final item in current)
        if (available(item)) reordered[index++] else item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final current = _current(context.watch<AppCubit>().state);
    final saved =
        context.select((SettingsCubit cubit) => cubit.state.musicLayout);
    final layout = _pending ?? saved;
    final onlyCategories = widget.libraryCategoriesOnly;
    final visible = layout.shortcuts.where(_shortcutAvailable).toList();
    final hidden = MusicShortcut.values
        .where((item) => _shortcutAvailable(item) && !visible.contains(item));
    final categories = layout.libraryCategories.where(_categoryAvailable);
    final heading = Theme.of(context).textTheme.titleMedium;

    void toggle(MusicShortcut item, bool show) {
      _save((value) {
        final shortcuts = List.of(value.shortcuts)..remove(item);
        if (show) shortcuts.add(item);
        return value.copyWith(shortcuts: shortcuts);
      });
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(onlyCategories
              ? locals.musicLayoutLibraryCategories
              : locals.customizeMusicLayout)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (!onlyCategories) ...[
            Text(locals.musicLayoutHelp),
            const SizedBox(height: 16),
            Text(locals.musicLayoutDestinations, style: heading),
            _ButtonOrder<MusicDestination>(
              keyPrefix: 'music-destination',
              items: layout.destinations,
              label: (item) => item.label(locals),
              enabled: current,
              onChanged: (items) =>
                  _save((value) => value.copyWith(destinations: items)),
            ),
            const Divider(),
            Text(locals.musicLayoutShortcuts, style: heading),
            _ButtonOrder<MusicShortcut>(
              keyPrefix: 'music-shortcut',
              items: visible,
              label: (item) => item.label(locals),
              enabled: current,
              onToggle: toggle,
              onChanged: (items) {
                // Keep the TV-only Search shortcut in its slot on touch devices.
                final reordered = _reorderAvailable(
                    layout.shortcuts, items, _shortcutAvailable);
                _save((value) => value.copyWith(shortcuts: reordered));
              },
            ),
            if (hidden.isNotEmpty) ...[
              Text(locals.phoneNavigationHidden, style: heading),
              for (final item in hidden)
                SwitchListTile(
                  key: ValueKey('music-shortcut-${item.name}-toggle'),
                  title: Text(item.label(locals)),
                  value: false,
                  onChanged: current ? (show) => toggle(item, show) : null,
                ),
            ],
            const Divider(),
            Text(locals.musicLayoutLibraryCategories, style: heading),
          ],
          Text(locals.musicLayoutLibraryCategoriesHelp),
          _ButtonOrder<MusicLibraryCategory>(
            keyPrefix: 'music-library-category',
            items: categories.toList(),
            label: (item) => item.label(locals),
            enabled: current,
            isChecked: (item) => !layout.hiddenLibraryCategories.contains(item),
            onToggle: (item, show) => _save((value) {
              final hidden = Set.of(value.hiddenLibraryCategories);
              if (show) {
                hidden.remove(item);
              } else {
                hidden.add(item);
              }
              return value.copyWith(hiddenLibraryCategories: hidden);
            }),
            onChanged: (items) {
              final reordered = _reorderAvailable(
                  layout.libraryCategories, items, _categoryAvailable);
              _save((value) => value.copyWith(libraryCategories: reordered));
            },
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('music-layout-reset'),
              onPressed: !current
                  ? null
                  : () => _save((value) => onlyCategories
                      ? value.copyWith(
                          libraryCategories: MusicLibraryCategory.values,
                          hiddenLibraryCategories: const {},
                        )
                      : const MusicLayout.defaults()),
              child: Text(onlyCategories
                  ? locals.musicLayoutLibraryCategoriesReset
                  : locals.musicLayoutReset),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ButtonOrder<T extends Enum> extends StatelessWidget {
  final String keyPrefix;
  final List<T> items;
  final String Function(T) label;
  final bool enabled;
  final ValueChanged<List<T>> onChanged;
  final void Function(T item, bool show)? onToggle;
  final bool Function(T item)? isChecked;

  const _ButtonOrder({
    required this.keyPrefix,
    required this.items,
    required this.label,
    required this.enabled,
    required this.onChanged,
    this.onToggle,
    this.isChecked,
  });

  void _move(int from, int to) {
    if (!enabled || from == to) return;
    final result = List.of(items);
    result.insert(to, result.removeAt(from));
    onChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: items.length,
      onReorder: (from, to) => _move(from, to > from ? to - 1 : to),
      itemBuilder: (context, index) {
        final item = items[index];
        final key = '$keyPrefix-${item.name}';
        return Row(key: ValueKey(key), children: [
          ReorderableDragStartListener(
            index: index,
            enabled: enabled,
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Icon(Icons.drag_handle,
                    semanticLabel: locals.phoneNavigationMove)),
          ),
          Expanded(
              child: onToggle == null
                  ? ListTile(
                      contentPadding: EdgeInsets.zero, title: Text(label(item)))
                  : SwitchListTile(
                      key: ValueKey('$key-toggle'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(label(item)),
                      value: isChecked?.call(item) ?? true,
                      onChanged:
                          enabled ? (show) => onToggle!(item, show) : null,
                    )),
          PopupMenuButton<bool>(
            key: ValueKey('$key-move'),
            enabled: enabled && items.length > 1,
            tooltip: '${locals.phoneNavigationMove} · ${label(item)}',
            onSelected: (earlier) =>
                _move(index, earlier ? index - 1 : index + 1),
            itemBuilder: (_) => [
              if (index > 0)
                PopupMenuItem(
                    value: true, child: Text(locals.phoneNavigationEarlier)),
              if (index < items.length - 1)
                PopupMenuItem(
                    value: false, child: Text(locals.phoneNavigationLater)),
            ],
          ),
        ]);
      },
    );
  }
}
