import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/states/app.dart';
import '../../../downloads/models/downloaded_video.dart';
import '../../../downloads/services/download_playback_source.dart';
import '../../../downloads/services/download_storage.dart';
import '../../../downloads/services/explicit_music_download.dart';
import '../../../downloads/states/download_manager.dart';
import '../../../globals.dart' show db;
import '../../../l10n/generated/app_localizations.dart';
import '../../../player/models/backend_playback.dart';
import '../../../utils/interfaces/db.dart';
import '../../../videos/models/video.dart';
import '../../models/music_library_entry.dart';
import '../../services/music_library_service.dart';

typedef _OfflineRequest = ({
  IDbClient database,
  AppState session,
  String id,
  String fingerprint,
  Video? song,
  String? pinnedFileProof,
});

// Android's storage worker uses a bounded queue shared with other file probes.
Future<void>? _pendingFileCheck;

Future<String?> _checkFile(
    DownloadedVideo file, bool Function() isCurrent) async {
  final preceding = _pendingFileCheck;
  final done = Completer<void>();
  _pendingFileCheck = done.future;
  try {
    if (preceding != null) await preceding;
    if (!isCurrent()) return null;
    return await DownloadStorage().musicFileProof(file, verifyCompletion: true);
  } finally {
    if (identical(_pendingFileCheck, done.future)) _pendingFileCheck = null;
    done.complete();
  }
}

/// Passive indicators for the exact item represented by a Music row.
class MusicStatusTitle extends StatefulWidget {
  MusicStatusTitle.song({super.key, required Video video, required this.child})
      : kind = MusicLibraryKind.song,
        id = video.videoId,
        _song = video,
        _download = null,
        _fileProof = null;

  const MusicStatusTitle.bookmark({
    super.key,
    required this.kind,
    required this.id,
    required this.child,
  })  : _song = null,
        _download = null,
        _fileProof = null;

  MusicStatusTitle.download({
    super.key,
    required DownloadedVideo file,
    String? fileProof,
    required this.child,
  })  : kind = MusicLibraryKind.song,
        id = file.videoId,
        _song = null,
        _download = file,
        _fileProof = fileProof;

  final MusicLibraryKind kind;
  final String id;
  final Widget child;
  final Video? _song;
  final DownloadedVideo? _download;
  final String? _fileProof;

  @override
  State<MusicStatusTitle> createState() => _MusicStatusTitleState();
}

class _MusicStatusTitleState extends State<MusicStatusTitle>
    with WidgetsBindingObserver {
  late bool _foreground;
  _OfflineRequest? _request;
  Future<bool>? _probe;

  @override
  void initState() {
    super.initState();
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    setState(() {
      _foreground = foreground;
      _request = null;
      _probe = null;
    });
  }

  Future<bool> _verify(_OfflineRequest request) async {
    final (
      database: database,
      session: session,
      id: id,
      fingerprint: fingerprint,
      song: song,
      pinnedFileProof: pinnedFileProof
    ) = request;

    bool current() =>
        mounted &&
        _foreground &&
        identical(_request, request) &&
        identical(db, database) &&
        database.profileId == session.profileId &&
        context.read<AppCubit?>()?.state == session;

    try {
      final file = readyMusicDownload(database, id, fingerprint: fingerprint);
      final provenance = file?.playbackProvenance;
      if (file == null ||
          provenance == null ||
          provenance.profileId != file.profileId ||
          provenance.accountId != file.accountId ||
          provenance.contentId != id ||
          !provenance.audioOnly ||
          provenance.container != file.container) {
        return false;
      }
      BackendPlayback? route;
      if (song != null) {
        final server = session.server;
        if (server == null) return false;
        final prepared = await prepareDownloadedPlaybackVideo(
          database: database,
          video: song,
          audioOnly: true,
          server: server,
          isCurrent: current,
        );
        final admitted = admittedMusicDownload(prepared);
        if (!current() ||
            admitted == null ||
            musicDownloadFingerprint(admitted) != fingerprint) {
          return false;
        }
        route = prepared!.playbackConnection;
      }
      final proof = await _checkFile(file, current);
      if (!current() ||
          proof == null ||
          (pinnedFileProof != null && pinnedFileProof != proof)) {
        return false;
      }
      if (route != null &&
          !route.matches(await database.getCurrentlySelectedServer())) {
        return false;
      }
      return current() &&
          readyMusicDownload(database, id, fingerprint: fingerprint) != null;
    } catch (_) {
      return false;
    }
  }

  _OfflineRequest? _offlineRequest(IDbClient database, AppState session) {
    final song = widget._song;
    final download = widget._download;
    if (song == null && download == null) return null;

    // DownloadManager publishes completions, removals, and replacements. Read
    // the persisted record, which is also what the playback resolver admits.
    final pinned = song?.explicitMusicDownload;
    final fingerprint = context.select((DownloadManagerCubit? _) {
      final file = readyMusicDownload(database, widget.id, fingerprint: pinned);
      return file?.playbackProvenance == null
          ? null
          : musicDownloadFingerprint(file!);
    });
    if (!_foreground ||
        !TickerMode.of(context) ||
        !(ModalRoute.isCurrentOf(context) ?? true) ||
        fingerprint == null ||
        (download != null &&
            musicDownloadFingerprint(download) != fingerprint)) {
      return null;
    }
    return (
      database: database,
      session: session,
      id: widget.id,
      fingerprint: fingerprint,
      song: song == null || pinned != null
          ? null
          : Video(
              videoId: song.videoId,
              liveNow: song.liveNow,
              adaptiveFormats: song.adaptiveFormats),
      pinnedFileProof: pinned == null
          ? widget._fileProof
          : pinnedMusicDownloadFileProof(pinned),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppCubit?>()?.state;
    if (session == null ||
        session.globalLoading ||
        session.sessionRecoveryRequired) {
      _request = null;
      _probe = null;
      return widget.child;
    }
    final database = db;
    if (database.profileId != session.profileId) {
      _request = null;
      _probe = null;
      return widget.child;
    }
    final request = _offlineRequest(database, session);
    if (request != _request) {
      _request = request;
      _probe = request == null ? null : _verify(request);
    }
    final library = MusicLibraryService.forProfile(database, session.profileId);
    return ListenableBuilder(
      listenable: library.changes,
      builder: (context, _) => FutureBuilder<bool>(
        future: _probe,
        builder: (context, check) {
          final saved = library.contains(widget.kind, widget.id);
          final offline = check.connectionState == ConnectionState.done &&
              check.data == true;
          if (!saved && !offline) return widget.child;
          final locals = AppLocalizations.of(context)!;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: widget.child),
              if (saved) _indicator(Icons.bookmark, locals.musicStatusSaved),
              if (offline)
                _indicator(
                    Icons.offline_pin, locals.musicStatusPlayableOffline),
            ],
          );
        },
      ),
    );
  }

  Widget _indicator(IconData icon, String label) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 6),
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: Icon(icon, size: 16, semanticLabel: label),
        ),
      );
}
