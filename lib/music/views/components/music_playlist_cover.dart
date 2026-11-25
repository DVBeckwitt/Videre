import 'package:clipious/app/states/app.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_playlist_covers.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'music_library_actions.dart';

class MusicPlaylistCoverImage extends StatefulWidget {
  final String? encoded;
  final Widget fallback;
  final double? size;

  const MusicPlaylistCoverImage(
      {super.key, required this.encoded, required this.fallback, this.size});

  @override
  State<MusicPlaylistCoverImage> createState() =>
      _MusicPlaylistCoverImageState();
}

class _MusicPlaylistCoverImageState extends State<MusicPlaylistCoverImage> {
  late Uint8List? _bytes = MusicPlaylistCovers.decode(widget.encoded);

  @override
  void didUpdateWidget(MusicPlaylistCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.encoded != oldWidget.encoded) {
      _bytes = MusicPlaylistCovers.decode(widget.encoded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return widget.fallback;
    return Image.memory(bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => widget.fallback);
  }
}

class MusicPlaylistCoverEditor extends StatefulWidget {
  final MusicPlaylistCovers covers;
  final String playlistId;

  const MusicPlaylistCoverEditor(
      {super.key, required this.covers, required this.playlistId});

  @override
  State<MusicPlaylistCoverEditor> createState() =>
      _MusicPlaylistCoverEditorState();
}

class _MusicPlaylistCoverEditorState extends State<MusicPlaylistCoverEditor> {
  static const _files = MethodChannel('videre/files');
  final _chooseFocus = FocusNode();
  final _resetFocus = FocusNode();
  bool _busy = false;

  @override
  void dispose() {
    _chooseFocus.dispose();
    _resetFocus.dispose();
    super.dispose();
  }

  Future<void> _edit({required bool reset}) async {
    if (_busy) return;
    final session = MusicLibrarySession(context.read<AppCubit>());
    final source = widget;
    if (!session.isCurrent ||
        session.library.profileId != source.covers.profileId) {
      return;
    }
    final route = ModalRoute.of(context);
    bool isCurrent() =>
        mounted &&
        widget.playlistId == source.playlistId &&
        route?.isCurrent != false &&
        session.isCurrent &&
        session.playlists.any((item) =>
            item.playlistId == source.playlistId && !item.isEditLocked);
    if (!isCurrent()) return;
    final hadFocus = (reset ? _resetFocus : _chooseFocus).hasFocus;
    final locals = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final bool changed;
      if (reset) {
        changed =
            await source.covers.reset(source.playlistId, isCurrent: isCurrent);
      } else {
        final bytes = await _files.invokeMethod<Uint8List>('openPlaylistCover');
        if (bytes == null || !isCurrent()) return;
        changed = await source.covers
            .save(source.playlistId, bytes, isCurrent: isCurrent);
      }
      if (changed && mounted && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(reset
                ? locals.musicPlaylistCoverReset
                : locals.musicPlaylistCoverUpdated)));
      }
    } catch (_) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(reset
                ? locals.musicLibraryActionError
                : locals.musicPlaylistCoverPickError)));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (hadFocus) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && isCurrent()) _chooseFocus.requestFocus();
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final encoded = widget.covers.encodedCover(widget.playlistId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (encoded != null)
          MusicPlaylistCoverImage(
            encoded: encoded,
            fallback: const SizedBox.shrink(),
            size: 120,
          ),
        if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
          Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                focusNode: _chooseFocus,
                onPressed: _busy ? null : () => _edit(reset: false),
                icon: const Icon(Icons.image_outlined),
                label: Text(locals.musicChoosePlaylistCover),
              ),
              if (encoded != null)
                TextButton(
                  focusNode: _resetFocus,
                  onPressed: _busy ? null : () => _edit(reset: true),
                  child: Text(locals.musicResetPlaylistCover),
                ),
            ],
          ),
      ],
    );
  }
}
