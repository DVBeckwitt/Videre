import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../globals.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../utils/interfaces/db.dart';
import '../../../utils/motion.dart';
import '../../../videos/models/video.dart';
import '../../services/ytdlnis_download.dart';

class YtdlnisDownloadAction extends StatefulWidget {
  final Video video;
  final bool audioOnly;
  final bool Function()? canDownload;

  const YtdlnisDownloadAction({
    super.key,
    required this.video,
    required this.audioOnly,
    this.canDownload,
  });

  @override
  State<YtdlnisDownloadAction> createState() => _YtdlnisDownloadActionState();
}

class _YtdlnisDownloadActionState extends State<YtdlnisDownloadAction> {
  late final IDbClient _database;
  late final String _profile;
  late final AppCubit? _app;
  late final int? _session;
  bool _opening = false;
  YtdlnisOpenResult? _result;

  @override
  void initState() {
    super.initState();
    _database = db;
    _profile = _database.profileId;
    _app = context.read<AppCubit?>();
    _session = _app?.state.sessionRevision;
  }

  bool get _current =>
      mounted &&
      ModalRoute.isCurrentOf(context) != false &&
      identical(db, _database) &&
      db.profileId == _profile &&
      (_app == null ||
          (!_app.isClosed &&
              _app.state.profileId == _profile &&
              _app.state.sessionRevision == _session &&
              !_app.state.globalLoading &&
              !_app.state.sessionRecoveryRequired)) &&
      widget.canDownload?.call() != false;

  Future<void> _open() async {
    if (_opening || !_current) return;
    setState(() {
      _opening = true;
      _result = null;
    });
    final result =
        await YtdlnisDownload.open(widget.video, audioOnly: widget.audioOnly);
    if (!mounted) return;
    if (_current && result == YtdlnisOpenResult.opened) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _opening = false;
        _result = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!YtdlnisDownload.canOpen(widget.video)) return const SizedBox.shrink();
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final status = _opening
        ? locals.ytdlnisOpening
        : switch (_result) {
            YtdlnisOpenResult.unavailable => locals.ytdlnisUnavailable,
            YtdlnisOpenResult.failed => locals.ytdlnisOpenFailed,
            _ => null,
          };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(locals.ytdlnisDownloadHelp, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: _opening ? null : _open,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: _opening
                  ? const ExcludeSemantics(
                      child: SizedBox.square(
                        dimension: 18,
                        child: MotionLoadingIndicator(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    )
                  : const Icon(Icons.open_in_new, size: 18),
              label: Text(locals.downloadWithYtdlnis,
                  textAlign: TextAlign.center)),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(status,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: _opening ? null : theme.colorScheme.error)),
              ),
            ),
        ],
      ),
    );
  }
}
