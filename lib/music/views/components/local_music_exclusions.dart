import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_track.dart';
import '../../services/local_music_library.dart';

Future<void> showLocalMusicExclusions(
    BuildContext context, LocalMusicLibrary library) async {
  final locals = AppLocalizations.of(context)!;
  final profile = library.visibilityProfile;
  await _showSheet<void>(context, library, profile, locals.localMusicExclusions,
      (context) {
    final folders = library.exclusionFolders;
    final included = library.inclusionFolders;
    final excluded = folders.where(library.isFolderExcluded);
    return ListView(
      shrinkWrap: true,
      children: [
        SwitchListTile(
          autofocus: isTv,
          value: library.excludesRecordings,
          title: Text(locals.localMusicExcludeRecordings),
          subtitle: Text(locals.localMusicExcludeRecordingsDescription),
          onChanged: (value) => updateLocalMusicExclusions(context, library,
              profile, () => library.setExcludeRecordings(value)),
        ),
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: Text(locals.localMusicIncludeFolder),
          subtitle: Text(locals.localMusicIncludeFolderDescription),
          onTap: folders.any((folder) => !library.isFolderIncluded(folder))
              ? () => _chooseFolder(context, library, profile, include: true)
              : null,
        ),
        if (included.isNotEmpty)
          ListTile(
            title: Semantics(
                header: true, child: Text(locals.localMusicIncludedFolders)),
          ),
        for (final folder in included)
          _folderRule(
            locals,
            folder,
            tooltip:
                locals.localMusicRemoveFolderInclusionTooltip(folder.label),
            onRemove: () => updateLocalMusicExclusions(context, library,
                profile, () => library.setFolderIncluded(folder, false)),
          ),
        ListTile(
          leading: const Icon(Icons.folder_off_outlined),
          title: Text(locals.localMusicExcludeFolder),
          subtitle: Text(locals.localMusicExcludeFolderDescription),
          onTap: folders.any((folder) => !library.isFolderExcluded(folder))
              ? () => _chooseFolder(context, library, profile, include: false)
              : null,
        ),
        if (excluded.isNotEmpty)
          ListTile(
            title: Semantics(
                header: true, child: Text(locals.localMusicExcludedFolders)),
          ),
        for (final folder in excluded)
          _folderRule(
            locals,
            folder,
            tooltip:
                locals.localMusicRemoveFolderExclusionTooltip(folder.label),
            onRemove: () => updateLocalMusicExclusions(context, library,
                profile, () => library.setFolderExcluded(folder, false)),
          ),
        ListTile(
          leading: const Icon(Icons.visibility_off_outlined),
          trailing: const Icon(Icons.chevron_right),
          title: Text(locals.localMusicExcludedFiles),
          onTap: () => _showExcludedFiles(context, library, profile),
        ),
      ],
    );
  });
}

Widget _folderRule(AppLocalizations locals, LocalMusicFolderLocation folder,
    {required String tooltip, required VoidCallback onRemove}) {
  return ListTile(
    key: ValueKey((folder.key, tooltip)),
    title: Text(folder.label),
    trailing: Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onRemove,
        child: Text(locals.localMusicRemoveFolderExclusion),
      ),
    ),
  );
}

Future<void> _chooseFolder(
    BuildContext context, LocalMusicLibrary library, Object? profile,
    {required bool include}) async {
  final locals = AppLocalizations.of(context)!;
  final title =
      include ? locals.localMusicIncludeFolder : locals.localMusicExcludeFolder;
  final configured =
      include ? library.isFolderIncluded : library.isFolderExcluded;
  final picked = await _showSheet<LocalMusicFolderLocation>(
      context, library, profile, title, (context) {
    final options = library.exclusionFolders
        .where((folder) => !configured(folder))
        .toList(growable: false);
    if (options.isEmpty) {
      return ListTile(title: Text(locals.localMusicNoIndexedFolders));
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: options.length,
      itemBuilder: (context, index) {
        final folder = options[index];
        return ListTile(
          key: ValueKey(folder.key),
          autofocus: isTv && index == 0,
          title: Text(folder.label),
          onTap: () => Navigator.of(context).pop(folder),
        );
      },
    );
  });
  if (picked == null || !context.mounted) return;
  await updateLocalMusicExclusions(
      context,
      library,
      profile,
      () => include
          ? library.setFolderIncluded(picked, true)
          : library.setFolderExcluded(picked, true));
}

Future<void> _showExcludedFiles(
    BuildContext context, LocalMusicLibrary library, Object? profile) async {
  final locals = AppLocalizations.of(context)!;
  await _showSheet<void>(
      context, library, profile, locals.localMusicExcludedFiles, (context) {
    final files = library.excludedTracks;
    if (files.isEmpty) {
      return ListTile(title: Text(locals.localMusicNoExcludedFiles));
    }
    final autofocus =
        isTv ? files.indexWhere(library.canKeepExcludedTrack) : -1;
    return ListView.builder(
      shrinkWrap: true,
      itemCount: files.length,
      itemBuilder: (context, index) {
        final track = files[index];
        final keep = library.canKeepExcludedTrack(track);
        final metadata = [
          track.artist,
          if (track.fileName != track.title) track.fileName,
        ].nonNulls.where((value) => value.trim().isNotEmpty).join(' • ');
        final reasons = [
          if (library.excludesRecordings && track.isRecording)
            locals.localMusicRecordingReason,
          if (track.folderLocations.any(library.isFolderExcluded))
            locals.localMusicFolderReason,
          if (library.isExcludedByInclusion(track))
            locals.localMusicOutsideIncludedFolders,
        ].join(' • ');
        return ListTile(
          key: ValueKey(track.playbackId),
          title:
              Text(track.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (metadata.isNotEmpty)
                Text(metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (reasons.isNotEmpty) Text(reasons),
            ],
          ),
          trailing: keep
              ? ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 136),
                  child: Tooltip(
                    message: locals.localMusicKeepInLibraryTooltip(track.title),
                    child: TextButton(
                      autofocus: index == autofocus,
                      onPressed: () => updateLocalMusicExclusions(
                          context,
                          library,
                          profile,
                          () => library.canKeepExcludedTrack(track)
                              ? library.setExclusionOverride(track, true)
                              : Future.value(false)),
                      child: Text(locals.localMusicKeepInLibrary,
                          textAlign: TextAlign.center),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  });
}

Future<T?> _showSheet<T>(BuildContext context, LocalMusicLibrary library,
    Object? profile, String title, WidgetBuilder body) {
  return showModalBottomSheet<T>(
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
        child: ListenableBuilder(
          listenable: library,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Semantics(
                    header: true,
                    child: Text(title,
                        style: Theme.of(context).textTheme.titleLarge)),
                trailing: CloseButton(onPressed: () => Navigator.pop(context)),
              ),
              if (library.visibilityProfile == profile)
                Flexible(child: body(context)),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> updateLocalMusicExclusions(
    BuildContext context,
    LocalMusicLibrary library,
    Object? profile,
    Future<bool> Function() update) async {
  if (!context.mounted || library.visibilityProfile != profile) return;
  try {
    await update();
  } catch (_) {
    if (!context.mounted || library.visibilityProfile != profile) return;
    final locals = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(locals.localMusicExclusionError)));
  }
}
