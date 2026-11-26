import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../playlists/models/playlist.dart';
import '../../../videos/models/video.dart';

typedef MusicPlaylistMembershipResult = ({int changed, int skipped});

Future<void> showMusicPlaylistMembershipEditor(
  BuildContext context, {
  required Video song,
  required List<Playlist> playlists,
  required bool Function() isProfileCurrent,
  required Stream<Object?> profileChanges,
  required Future<MusicPlaylistMembershipResult> Function(Map<String, bool>)
      apply,
  bool inPlayer = false,
}) async {
  if (!isProfileCurrent()) return;
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final locals = AppLocalizations.of(context)!;
  final route = DialogRoute<MusicPlaylistMembershipResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MembershipDialog(
      song: song,
      playlists: playlists,
      isProfileCurrent: isProfileCurrent,
      apply: apply,
      inPlayer: inPlayer,
    ),
  );

  final profileSubscription = profileChanges.listen((_) {
    if (!isProfileCurrent() && route.isActive && navigator.mounted) {
      navigator.removeRoute(route);
    }
  });
  try {
    final result = await navigator.push(route);
    if (result == null || !messenger.mounted || !isProfileCurrent()) return;
    final message = [
      if (result.changed > 0)
        locals.musicPlaylistMembershipsUpdated(result.changed),
      if (result.skipped > 0)
        locals.musicPlaylistMembershipsSkipped(result.skipped),
      if (result.changed == 0 && result.skipped == 0)
        locals.musicPlaylistMembershipsUnchanged,
    ].join('\n');
    messenger.showSnackBar(SnackBar(content: Text(message)));
  } finally {
    await profileSubscription.cancel();
  }
}

class _MembershipDialog extends StatefulWidget {
  final Video song;
  final List<Playlist> playlists;
  final bool Function() isProfileCurrent;
  final Future<MusicPlaylistMembershipResult> Function(Map<String, bool>) apply;
  final bool inPlayer;

  const _MembershipDialog({
    required this.song,
    required this.playlists,
    required this.isProfileCurrent,
    required this.apply,
    required this.inPlayer,
  });

  @override
  State<_MembershipDialog> createState() => _MembershipDialogState();
}

class _MembershipDialogState extends State<_MembershipDialog> {
  final _draft = <String, bool>{};
  late final List<({Playlist playlist, int copies})> _destinations;
  bool _applying = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final ids = <String>{};
    final destinations = [
      for (final (index, playlist) in widget.playlists.indexed)
        if (playlist.isLocal &&
            !playlist.isEditLocked &&
            ids.add(playlist.playlistId))
          (index, playlist),
    ]..sort((a, b) {
        final byUpdated = (b.$2.updated ?? 0).compareTo(a.$2.updated ?? 0);
        return byUpdated == 0 ? a.$1.compareTo(b.$1) : byUpdated;
      });
    _destinations = [
      for (final (_, playlist) in destinations)
        (
          playlist: playlist,
          copies: playlist.videos
              .where((entry) => entry.videoId == widget.song.videoId)
              .length,
        ),
    ];
  }

  Future<void> _apply() async {
    if (_applying || _draft.isEmpty) return;
    final route = ModalRoute.of(context)!;
    void finish([MusicPlaylistMembershipResult? result]) {
      if (route.isCurrent) {
        route.navigator?.pop(result);
      } else if (route.isActive) {
        route.navigator?.removeRoute(route, result);
      }
    }

    if (!widget.isProfileCurrent()) {
      finish();
      return;
    }
    setState(() {
      _applying = true;
      _failed = false;
    });
    try {
      final result = await widget.apply(Map.of(_draft));
      if (mounted) finish(widget.isProfileCurrent() ? result : null);
    } catch (_) {
      if (!mounted || !route.isActive) return;
      if (!widget.isProfileCurrent()) {
        finish();
        return;
      }
      setState(() {
        _applying = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final title = widget.song.musicMetadata?.title ?? widget.song.title;
    final dialog = PopScope<MusicPlaylistMembershipResult>(
      canPop: !_applying,
      child: AlertDialog(
        scrollable: true,
        title: Text(locals.musicManageSongPlaylists),
        content: SizedBox(
          width: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null) ...[
                Text(title),
                const SizedBox(height: 8),
              ],
              Text(_destinations.isEmpty
                  ? locals.musicPlaylistMembershipsEmpty
                  : locals.musicPlaylistMembershipsHelp),
              for (final (:playlist, :copies) in _destinations)
                CheckboxListTile(
                  key: ValueKey(
                      ('music-playlist-membership', playlist.playlistId)),
                  contentPadding: EdgeInsets.zero,
                  title: Text(playlist.playlistId == localWatchLaterId
                      ? locals.watchLater
                      : playlist.title),
                  subtitle: Text(locals.musicPlaylistMembershipCount(
                      locals.musicTrackCount(playlist.videos.length), copies)),
                  value: _draft[playlist.playlistId] ?? copies > 0,
                  onChanged: _applying
                      ? null
                      : (value) => setState(() {
                            if (value == null || value == (copies > 0)) {
                              _draft.remove(playlist.playlistId);
                            } else {
                              _draft[playlist.playlistId] = value;
                            }
                          }),
                ),
              if (_applying) const LinearProgressIndicator(),
              if (_failed) Text(locals.musicLibraryActionError),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _applying ? null : () => Navigator.of(context).pop(),
            child: Text(locals.cancel),
          ),
          FilledButton(
            onPressed: _applying || _draft.isEmpty ? null : _apply,
            child: Text(locals.musicPlaylistMembershipsApply),
          ),
        ],
      ),
    );
    if (!widget.inPlayer) return dialog;
    return PlayerModalBackHandler(
      priority: 5,
      onBack: () {
        if (!_applying) Navigator.of(context).pop();
      },
      child: dialog,
    );
  }
}
