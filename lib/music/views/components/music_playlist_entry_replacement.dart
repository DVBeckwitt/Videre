import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/models/music_catalog_search.dart';
import 'package:clipious/music/models/music_track.dart';
import 'package:clipious/music/services/music_catalog_service.dart';
import 'package:clipious/network/network_proxy.dart';
import 'package:clipious/utils.dart' show selectKeys;
import 'package:clipious/utils/motion.dart';
import 'package:clipious/videos/models/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_duration_label.dart';

Future<void> showMusicPlaylistEntryReplacement(
  BuildContext context, {
  required Video original,
  required bool Function() isCurrent,
  required Future<bool> Function(bool Function() isCurrent) hasOfflineSource,
  required Future<bool> Function(Video replacement, bool Function() isCurrent)
      onReplace,
}) {
  final app = context.read<AppCubit>();
  final proxy = NetworkProxy.instance;
  final config = proxy.config;
  bool current() =>
      isCurrent() && !proxy.isChanging && identical(proxy.config, config);
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    animationStyle: AppMotion.dialogStyle(context),
    builder: (_) => BlocListener<AppCubit, AppState>(
      bloc: app,
      listenWhen: (_, __) => !current(),
      listener: (context, _) {
        final route = ModalRoute.of(context);
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      },
      child: Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: _ReplacementDialog(
          original: original,
          isCurrent: current,
          hasOfflineSource: hasOfflineSource,
          onReplace: onReplace,
        ),
      ),
    ),
  );
}

class _ReplacementDialog extends StatefulWidget {
  const _ReplacementDialog({
    required this.original,
    required this.isCurrent,
    required this.hasOfflineSource,
    required this.onReplace,
  });

  final Video original;
  final bool Function() isCurrent;
  final Future<bool> Function(bool Function() isCurrent) hasOfflineSource;
  final Future<bool> Function(Video replacement, bool Function() isCurrent)
      onReplace;

  @override
  State<_ReplacementDialog> createState() => _ReplacementDialogState();
}

class _ReplacementDialogState extends State<_ReplacementDialog> {
  final _catalog = musicCatalogService;
  late final _query = TextEditingController(
    text: [
      widget.original.musicMetadata!.title,
      widget.original.musicMetadata!.artist,
    ].join(' ').trim(),
  );
  MusicRecordingAvailability? _availability;
  List<MusicTrack>? _results;
  MusicTrack? _candidate;
  String? _error;
  bool _busy = false;
  ModalRoute<dynamic>? _route;

  bool get _visible => mounted && _route?.isCurrent == true;
  bool _isCurrent() => _visible && widget.isCurrent();
  AppLocalizations get _locals => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_visible) _checkOriginal();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String error) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_isCurrent()) throw StateError('The Music connection changed.');
      await action();
      if (_visible && !_isCurrent()) _error = error;
    } catch (_) {
      _error = error;
    } finally {
      if (mounted && _route?.isActive == true) setState(() => _busy = false);
    }
  }

  Future<MusicRecordingAvailability> _probeOriginal() async {
    final availability = await _catalog.checkRecordingAvailability(
        widget.original.videoId,
        isCurrent: _isCurrent);
    if (!_isCurrent()) throw StateError('The Music connection changed.');
    if (availability == MusicRecordingAvailability.missing &&
        await widget.hasOfflineSource(_isCurrent)) {
      return MusicRecordingAvailability.available;
    }
    return availability;
  }

  void _checkOriginal() => _run(() async {
        final availability = await _probeOriginal();
        if (_isCurrent()) _availability = availability;
      }, _locals.musicPlaylistEntryCheckFailed);

  void _search() {
    final query = _query.text.trim();
    if (_busy || query.isEmpty) return;
    FocusScope.of(context).unfocus();
    _results = null;
    _run(() async {
      final page = await _catalog.searchPage(
        query,
        MusicCatalogSearchType.songs,
        1,
        isCurrent: _isCurrent,
      );
      if (!_isCurrent()) return;
      _results = [
        for (final hit in page.hits)
          if (hit case MusicCatalogSongHit(:final track)
              when track.videoId != widget.original.videoId)
            track,
      ];
    }, _locals.musicPlaylistReplacementSearchFailed);
  }

  void _confirm(MusicTrack candidate) {
    final locals = _locals;
    _run(() async {
      final candidateStatus = await _catalog
          .checkRecordingAvailability(candidate.videoId, isCurrent: _isCurrent);
      if (!_isCurrent()) return;
      if (candidateStatus != MusicRecordingAvailability.available) {
        _error = locals.musicPlaylistReplacementUnavailable;
        return;
      }
      final originalStatus = await _probeOriginal();
      if (!_isCurrent()) return;
      _availability = originalStatus;
      if (originalStatus != MusicRecordingAvailability.missing) return;
      if (await _save(candidate)) {
        if (mounted && _route?.isCurrent == true) Navigator.of(context).pop();
      } else {
        _error = locals.musicLibraryActionError;
      }
    }, locals.musicPlaylistEntryCheckFailed);
  }

  Future<bool> _save(MusicTrack candidate) async {
    try {
      return await widget.onReplace(candidate.toVideo(), _isCurrent);
    } catch (_) {
      return false;
    }
  }

  Widget _recording(Video video) {
    final music = video.musicMetadata!;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(music.title),
      subtitle: Text([
        if (music.artist.isNotEmpty) music.artist,
        if (music.album case final album? when album.isNotEmpty) album,
        if (video.lengthSeconds case final length? when length > 0)
          formatMusicDuration(length),
      ].join(' · ')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locals = _locals;
    final candidate = _candidate;
    final missing = _availability == MusicRecordingAvailability.missing;
    return AlertDialog(
      scrollable: true,
      title: Text(locals.musicReplacePlaylistEntry),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _recording(widget.original),
            if (_availability == MusicRecordingAvailability.available)
              Semantics(
                liveRegion: true,
                child: Text(locals.musicPlaylistEntryStillAvailable),
              ),
            if (missing && candidate == null) ...[
              Text(locals.musicPlaylistEntryMissing),
              TextField(
                key: const ValueKey('music-playlist-replacement-search'),
                controller: _query,
                enabled: !_busy,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: locals.musicPlaylistReplacementSearch,
                  suffixIcon: IconButton(
                    onPressed: _busy ? null : _search,
                    tooltip: locals.search,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: (_) => _search(),
              ),
              if (_results case final results?)
                if (results.isEmpty)
                  Text(locals.musicNoResults)
                else
                  for (final track in results)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(track.title),
                      subtitle: Text(track.artists.join(', ')),
                      onTap: _busy
                          ? null
                          : () => setState(() {
                                _candidate = track;
                                _error = null;
                              }),
                    ),
            ],
            if (missing && candidate != null) ...[
              Text(locals.musicPlaylistReplacementRecording),
              _recording(candidate.toVideo()),
            ],
            if (_busy)
              const LinearProgressIndicator()
            else if (_error case final error?)
              Semantics(
                liveRegion: true,
                child: Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(locals.cancel),
        ),
        if (!_busy && _availability == null && _error != null)
          FilledButton(onPressed: _checkOriginal, child: Text(locals.retry)),
        if (missing && candidate != null) ...[
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _candidate = null;
                      _error = null;
                    }),
            child: Text(locals.musicChooseAnotherReplacement),
          ),
          FilledButton(
            onPressed: _busy ? null : () => _confirm(candidate),
            child: Text(locals.musicConfirmPlaylistEntryReplacement),
          ),
        ],
      ],
    );
  }
}
