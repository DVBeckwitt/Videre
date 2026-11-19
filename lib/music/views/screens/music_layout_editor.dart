import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../settings/states/settings.dart';
import '../../models/music_layout.dart';

class MusicLayoutEditor extends StatefulWidget {
  final bool includeSearchShortcut;

  const MusicLayoutEditor({super.key, this.includeSearchShortcut = false});

  static Future<void> open(BuildContext context,
          {bool includeSearchShortcut = false}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) =>
              MusicLayoutEditor(includeSearchShortcut: includeSearchShortcut)));

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

  Future<void> _save(MusicLayout layout) async {
    if (!_current(context.read<AppCubit>().state)) return;
    final revision = ++_editRevision;
    // Writes run in order. Keep the latest edit interactive while the database
    // catches up, including when moving several buttons with a TV remote.
    setState(() => _pending = layout);
    try {
      await context.read<SettingsCubit>().setMusicLayout(layout);
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

  bool _available(MusicShortcut item) =>
      widget.includeSearchShortcut || item != MusicShortcut.search;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final current = _current(context.watch<AppCubit>().state);
    final saved =
        context.select((SettingsCubit cubit) => cubit.state.musicLayout);
    final layout = _pending ?? saved;
    final visible = layout.shortcuts.where(_available).toList();
    final hidden = MusicShortcut.values
        .where((item) => _available(item) && !visible.contains(item));
    final heading = Theme.of(context).textTheme.titleMedium;

    void toggle(MusicShortcut item, bool show) {
      final shortcuts = List.of(layout.shortcuts)..remove(item);
      if (show) shortcuts.add(item);
      _save(layout.copyWith(shortcuts: shortcuts));
    }

    return Scaffold(
      appBar: AppBar(title: Text(locals.customizeMusicLayout)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(locals.musicLayoutHelp),
          const SizedBox(height: 16),
          Text(locals.musicLayoutDestinations, style: heading),
          _ButtonOrder<MusicDestination>(
            keyPrefix: 'music-destination',
            items: layout.destinations,
            label: (item) => item.label(locals),
            enabled: current,
            onChanged: (items) => _save(layout.copyWith(destinations: items)),
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
              var index = 0;
              _save(layout.copyWith(shortcuts: [
                for (final item in layout.shortcuts)
                  if (_available(item)) items[index++] else item
              ]));
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
          Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const ValueKey('music-layout-reset'),
                onPressed:
                    current ? () => _save(const MusicLayout.defaults()) : null,
                child: Text(locals.musicLayoutReset),
              )),
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

  const _ButtonOrder({
    required this.keyPrefix,
    required this.items,
    required this.label,
    required this.enabled,
    required this.onChanged,
    this.onToggle,
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
                      value: true,
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
