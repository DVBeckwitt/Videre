import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../utils.dart' show selectKeys;
import '../../models/local_music_scan_report.dart';
import '../../services/local_music_library.dart';
import 'local_music_locations.dart';

Future<void> showLocalMusicScanReport(
    BuildContext context, LocalMusicLibrary library) {
  final app = context.read<AppCubit?>();
  final session = app?.state;
  final profile = library.visibilityProfile;
  final roots = library.roots;

  bool isCurrent() {
    final state = app?.state;
    return context.mounted &&
        library.visibilityProfile == profile &&
        identical(library.roots, roots) &&
        state?.profileId == session?.profileId &&
        state?.sessionRevision == session?.sessionRevision &&
        state?.globalLoading != true &&
        state?.sessionRecoveryRequired != true;
  }

  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final locals = AppLocalizations.of(sheetContext)!;
      return Shortcuts(
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
                    child: Text(locals.localMusicScanReport,
                        style: Theme.of(sheetContext).textTheme.titleLarge)),
                trailing: IconButton(
                  autofocus: isTv,
                  tooltip:
                      MaterialLocalizations.of(sheetContext).closeButtonTooltip,
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
              Flexible(
                child: StreamBuilder<AppState>(
                  stream: app?.stream,
                  builder: (context, _) => ListenableBuilder(
                    listenable: library,
                    builder: (context, _) {
                      final current = isCurrent();
                      final report = current ? library.scanReport : null;
                      final scanning = current && library.scanning;
                      final needsAccess = current &&
                          library.roots.any(library.isRootUnavailable);
                      final canRescan =
                          current && !library.busy && !library.unavailable;
                      return CustomScrollView(
                        shrinkWrap: true,
                        slivers: [
                          SliverList.list(children: [
                            if (current)
                              ListTile(title: Text(locals.localMusicScanScope)),
                            if (scanning)
                              ListTile(
                                title: Text(locals.localMusicScanRunning),
                                subtitle: const LinearProgressIndicator(),
                              ),
                            if (report == null && !scanning)
                              ListTile(
                                  title:
                                      Text(locals.localMusicScanUnavailable)),
                            if (report != null && report.partial)
                              ListTile(
                                  title: Text(locals.localMusicScanIncomplete)),
                            if (report != null &&
                                report.locations.isNotEmpty &&
                                report.locations.every(
                                    (location) => location.skippedCount == 0))
                              ListTile(title: Text(locals.localMusicScanEmpty)),
                            if (current && !library.unavailable)
                              ListTile(
                                leading: const Icon(Icons.refresh),
                                title: Text(locals.localMusicScanRetry),
                                onTap: canRescan
                                    ? () {
                                        if (isCurrent()) library.refresh();
                                      }
                                    : null,
                              ),
                            if (needsAccess)
                              ListTile(
                                leading: const Icon(Icons.folder_copy_outlined),
                                title: Text(locals.localMusicManageLocations),
                                subtitle:
                                    Text(locals.localMusicReconnectLocation),
                                onTap: library.busy
                                    ? null
                                    : () {
                                        if (isCurrent()) {
                                          showLocalMusicLocations(
                                              context, library);
                                        }
                                      },
                              ),
                          ]),
                          for (final location in report?.locations ?? const [])
                            if (location.skippedCount > 0) ...[
                              SliverToBoxAdapter(
                                child: ListTile(
                                  title: Semantics(
                                    header: true,
                                    child: Text(location.root.isSystem
                                        ? locals.localMusicAndroidLibrary
                                        : location.root.name),
                                  ),
                                  subtitle: Text(
                                      locals.localMusicScanSkippedCount(
                                          location.skippedCount)),
                                ),
                              ),
                              SliverList.builder(
                                itemCount: location.files.length,
                                itemBuilder: (context, index) {
                                  final file = location.files[index];
                                  return ListTile(
                                    title: Text(file.name ??
                                        locals.localMusicScanUnnamedFile),
                                    subtitle:
                                        Text(_reason(locals, file.reason)),
                                  );
                                },
                              ),
                              if (location.skippedCount > location.files.length)
                                SliverToBoxAdapter(
                                  child: ListTile(
                                    title: Text(locals.localMusicScanOmitted(
                                        location.skippedCount -
                                            location.files.length)),
                                  ),
                                ),
                            ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String _reason(AppLocalizations locals, LocalMusicSkipReason reason) =>
    switch (reason) {
      LocalMusicSkipReason.playlist => locals.localMusicScanPlaylistFile,
      LocalMusicSkipReason.unsupportedType =>
        locals.localMusicScanUnsupportedType,
      LocalMusicSkipReason.missingDetails =>
        locals.localMusicScanMissingDetails,
      LocalMusicSkipReason.unknown => locals.localMusicScanUnknownReason,
    };
