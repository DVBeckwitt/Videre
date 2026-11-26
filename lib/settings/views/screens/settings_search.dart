import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../music/models/song_transition.dart';
import '../../../utils.dart' show selectKeys;
import '../../../utils/views/tv/components/tv_overscan.dart';
import '../../../utils/views/tv/components/tv_text_field.dart';
import '../../models/general_settings_search_entries.dart';
import '../../models/music_settings_search_entries.dart';
import '../../models/settings_search_entry.dart';
import '../../states/settings.dart';

final _remoteSelectShortcuts = <ShortcutActivator, Intent>{
  for (final key in selectKeys) SingleActivator(key): const ActivateIntent(),
};

void openSettingsSearch(BuildContext context, {required bool television}) {
  Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (_) => SettingsSearchScreen(television: television),
  ));
}

class SettingsSearchScreen extends StatefulWidget {
  final bool television;

  const SettingsSearchScreen({super.key, required this.television});

  @override
  State<SettingsSearchScreen> createState() => _SettingsSearchScreenState();
}

class _SettingsSearchScreenState extends State<SettingsSearchScreen> {
  final _query = TextEditingController();
  final _inputFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _query.addListener(_refreshResults);
  }

  void _refreshResults() => setState(() {});

  @override
  void dispose() {
    _inputFocus.dispose();
    _query.dispose();
    super.dispose();
  }

  void _clear() {
    _query.clear();
    _inputFocus.requestFocus();
  }

  void _openResult(SettingsSearchEntry entry) {
    if (!widget.television) _inputFocus.unfocus();
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => _SettingsSearchDestination(entry: entry),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final television = widget.television;
    final query = _query.text.trim();
    final results = query.isEmpty
        ? const <SettingsSearchEntry>[]
        : searchSettings(query, [
            ...musicSettingsSearchEntries(
              locals,
              television: television,
              direction: Directionality.of(context),
              showTransitionDuration: context.select((SettingsCubit cubit) =>
                  cubit.state.songTransitionMode !=
                  SongTransitionMode.seamless),
            ),
            ...generalSettingsSearchEntries(locals, television: television),
          ]);
    final clear = _query.text.isEmpty
        ? null
        : IconButton(
            tooltip: locals.settingsSearchClear,
            onPressed: _clear,
            icon: const Icon(Icons.clear),
          );
    final input = television
        ? Row(
            children: [
              Expanded(
                child: TvTextField(
                  key: const ValueKey('settings-search-input'),
                  autofocus: true,
                  focusNode: _inputFocus,
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  leading: const Icon(Icons.search),
                  decoration:
                      InputDecoration(label: Text(locals.settingsSearch)),
                ),
              ),
              if (clear != null) clear,
            ],
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              key: const ValueKey('settings-search-input'),
              autofocus: true,
              focusNode: _inputFocus,
              controller: _query,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: locals.settingsSearch,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: clear,
                border: const OutlineInputBorder(),
              ),
            ),
          );
    final content = SafeArea(
      child: Column(
        children: [
          input,
          if (query.isNotEmpty && results.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(locals.settingsSearchNoResults),
            ),
          if (results.isNotEmpty)
            Expanded(
              child: ListView.builder(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                itemCount: results.length,
                itemBuilder: (context, index) {
                  final entry = results[index];
                  return ListTile(
                    key: ValueKey('settings-search-result-${entry.id}'),
                    title: Text(entry.title),
                    subtitle: Text(entry.category),
                    onTap: () => _openResult(entry),
                  );
                },
              ),
            ),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(locals.settingsSearch)),
      body: television
          ? TvOverscan(
              child:
                  Shortcuts(shortcuts: _remoteSelectShortcuts, child: content))
          : content,
    );
  }
}

class _SettingsSearchDestination extends StatefulWidget {
  final SettingsSearchEntry entry;

  const _SettingsSearchDestination({required this.entry});

  @override
  State<_SettingsSearchDestination> createState() =>
      _SettingsSearchDestinationState();
}

class _SettingsSearchDestinationState
    extends State<_SettingsSearchDestination> {
  final _target = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !ModalRoute.of(context)!.isCurrent) return;
      final targetContext = _target.context;
      if (targetContext == null) return;
      Scrollable.ensureVisible(targetContext, alignment: 0.35);
      _target.requestFocus();
    });
  }

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: _remoteSelectShortcuts,
        child: widget.entry.destination(context, _target),
      );
}
