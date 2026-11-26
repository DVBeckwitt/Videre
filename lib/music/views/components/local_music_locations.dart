import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../services/local_music_library.dart';

Future<void> showLocalMusicLocations(
    BuildContext context, LocalMusicLibrary library) {
  final locals = AppLocalizations.of(context)!;
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Semantics(
                  header: true,
                  child: Text(locals.localMusicManageLocations,
                      style: Theme.of(context).textTheme.titleLarge)),
              trailing: CloseButton(onPressed: () => Navigator.pop(context)),
            ),
            Flexible(
              child: ListenableBuilder(
                listenable: library,
                builder: (context, _) {
                  final enabled = !library.busy;
                  final roots = library.roots;
                  final status = localMusicSourceStatus(library, locals);
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      ListTile(
                        autofocus: isTv,
                        leading: const Icon(Icons.create_new_folder_outlined),
                        title: Text(locals.localMusicAddFolder),
                        subtitle: Text(locals.localMusicFolderAccess),
                        onTap: enabled ? library.chooseFolder : null,
                      ),
                      ListTile(
                        leading: const Icon(Icons.folder_shared_outlined),
                        title: Text(locals.localMusicAddProviderFolder),
                        subtitle: Text(locals.localMusicProviderFolderAccess),
                        onTap: enabled ? library.chooseProviderFolder : null,
                      ),
                      if (!roots.any((root) => root.isSystem))
                        ListTile(
                          leading: const Icon(Icons.library_music_outlined),
                          title: Text(locals.localMusicUseAndroidLibrary),
                          subtitle: Text(locals.localMusicAndroidLibraryAccess),
                          onTap: enabled ? library.chooseSystem : null,
                        ),
                      ListTile(
                        leading: const Icon(Icons.tune),
                        title: Text(locals.localMusicTagSeparators),
                        subtitle: Text(locals.localMusicTagSeparatorsSummary),
                        onTap: enabled
                            ? () => _showTagSeparators(context, library)
                            : null,
                      ),
                      if (status != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(status),
                        ),
                      if (!enabled) const LinearProgressIndicator(),
                      for (final root in roots)
                        _LocationTile(library: library, root: root),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showTagSeparators(
    BuildContext context, LocalMusicLibrary library) async {
  final locals = AppLocalizations.of(context)!;
  final options = {
    ',': locals.localMusicTagSeparatorComma,
    ';': locals.localMusicTagSeparatorSemicolon,
    '/': locals.localMusicTagSeparatorSlash,
    '+': locals.localMusicTagSeparatorPlus,
    '&': locals.localMusicTagSeparatorAmpersand,
  };
  final selected = options.keys.where(library.tagSeparators.contains).toSet();
  final separators = await showDialog<String>(
    context: context,
    builder: (context) => Shortcuts(
      shortcuts: {
        for (final key in selectKeys)
          SingleActivator(key): const ActivateIntent(),
      },
      child: StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: Text(locals.localMusicTagSeparators),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(locals.localMusicTagSeparatorsHelp),
              const SizedBox(height: 8),
              for (final option in options.entries)
                CheckboxListTile(
                  autofocus: isTv && option.key == options.keys.first,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  title: Text(option.value),
                  value: selected.contains(option.key),
                  onChanged: (checked) => setDialogState(() {
                    if (checked == true) {
                      selected.add(option.key);
                    } else {
                      selected.remove(option.key);
                    }
                  }),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(locals.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                  context, options.keys.where(selected.contains).join()),
              child: Text(locals.save),
            ),
          ],
        ),
      ),
    ),
  );
  if (separators == null || !context.mounted) return;
  if (!await library.setTagSeparators(separators) && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(locals.localMusicTagSeparatorsError)));
  }
}

String? localMusicSourceStatus(
    LocalMusicLibrary library, AppLocalizations locals) {
  if (library.unavailable) {
    if (library.roots.length > 1) return locals.localMusicLocationsUnavailable;
    return library.isSystem
        ? locals.localMusicAndroidLibraryUnavailable
        : locals.localMusicFolderUnavailable;
  }
  return switch (library.error) {
    'AUDIO_PERMISSION_DENIED' => locals.localMusicAndroidLibraryUnavailable,
    'PICKER_UNAVAILABLE' => locals.localMusicPickerUnavailable,
    'SCAN_PARTIAL' => locals.localMusicScanPartial,
    'PROVIDER_FOLDER_UNAVAILABLE' => locals.localMusicProviderUnreachable,
    'RENAME_FAILED' ||
    'RENAME_CHANGED' ||
    'RENAME_ACCESS' ||
    'RENAME_INVALID_NAME' ||
    'RENAME_UNSUPPORTED' ||
    'RENAME_COLLISION' ||
    'SCAN_CANCELLED' ||
    null =>
      switch ((
        library.roots.any(library.isRootUnavailable),
        library.roots.any(library.isProviderUnreachable),
      )) {
        (true, _) => locals.localMusicSomeLocationsUnavailable,
        (_, true) => locals.localMusicProviderUnreachable,
        _ => null,
      },
    _ => library.isSystem
        ? locals.localMusicAndroidLibraryError
        : locals.localMusicFolderError,
  };
}

class _LocationTile extends StatelessWidget {
  const _LocationTile({required this.library, required this.root});

  final LocalMusicLibrary library;
  final LocalMusicRoot root;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final name = root.isSystem ? locals.localMusicAndroidLibrary : root.name;
    final unavailable = library.isRootUnavailable(root);
    final unreachable = library.isProviderUnreachable(root);
    final subtitle = unavailable
        ? locals.localMusicReconnectLocation
        : unreachable
            ? locals.localMusicProviderUnreachable
            : root.isDocumentProvider
                ? locals.localMusicProviderLocation
                : null;
    return ListTile(
      key: ValueKey(root.uri),
      leading: Icon(switch (root) {
        LocalMusicRoot(isSystem: true) => Icons.library_music_outlined,
        LocalMusicRoot(isDocumentProvider: true) =>
          Icons.folder_shared_outlined,
        _ => Icons.folder_outlined,
      }),
      title: Text(name),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: switch ((library.busy, unavailable, unreachable)) {
        (false, true, _) => root.isSystem
            ? library.chooseSystem
            : () => library.chooseFolder(reconnect: root),
        (false, false, true) => library.refresh,
        _ => null,
      },
      trailing: IconButton(
        tooltip: locals.localMusicRemoveLocation(name),
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: library.busy ? null : () => library.removeRoot(root),
      ),
    );
  }
}
