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
                      if (!roots.any((root) => root.isSystem))
                        ListTile(
                          leading: const Icon(Icons.library_music_outlined),
                          title: Text(locals.localMusicUseAndroidLibrary),
                          subtitle: Text(locals.localMusicAndroidLibraryAccess),
                          onTap: enabled ? library.chooseSystem : null,
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
    'RENAME_FAILED' ||
    'RENAME_CHANGED' ||
    'RENAME_ACCESS' ||
    'RENAME_INVALID_NAME' ||
    'RENAME_UNSUPPORTED' ||
    'RENAME_COLLISION' ||
    'SCAN_CANCELLED' ||
    null =>
      library.roots.any(library.isRootUnavailable)
          ? locals.localMusicSomeLocationsUnavailable
          : null,
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
    return ListTile(
      key: ValueKey(root.uri),
      leading: Icon(
          root.isSystem ? Icons.library_music_outlined : Icons.folder_outlined),
      title: Text(name),
      subtitle: unavailable ? Text(locals.localMusicReconnectLocation) : null,
      onTap: !unavailable || library.busy
          ? null
          : root.isSystem
              ? library.chooseSystem
              : () => library.chooseFolder(reconnect: root),
      trailing: IconButton(
        tooltip: locals.localMusicRemoveLocation(name),
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: library.busy ? null : () => library.removeRoot(root),
      ),
    );
  }
}
