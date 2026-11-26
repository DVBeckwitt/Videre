import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_lyric_share.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

typedef _LyricImagePreview = ({ShareParams params, Uint8List bytes});

class MusicLyricShareButton extends StatefulWidget {
  final List<String> lines;
  final MusicMetadata track;
  final String? source;
  final bool edited;
  final bool Function() isCurrent;
  final Future<List<File>> Function()? loadArtwork;

  const MusicLyricShareButton({
    super.key,
    required this.lines,
    required this.track,
    required this.source,
    required this.edited,
    required this.isCurrent,
    this.loadArtwork,
  });

  @override
  State<MusicLyricShareButton> createState() => _MusicLyricShareButtonState();
}

class _MusicLyricShareButtonState extends State<MusicLyricShareButton> {
  bool _sharing = false;
  bool _failed = false;

  Future<void> _share() async {
    final isCurrent = widget.isCurrent;
    if (_sharing || widget.lines.isEmpty || !isCurrent()) return;
    final locals = AppLocalizations.of(context)!;
    final artist = widget.track.artist.trim();
    final source = widget.source?.trim() ?? '';
    final excerpt = MusicLyricShare(
      lines: widget.lines,
      attribution: [
        widget.track.title,
        if (artist.isNotEmpty) artist,
        if (source.isNotEmpty) locals.musicLyricsShareSource(source),
        if (widget.edited) locals.musicLyricsShareEdited,
      ].join('\n'),
      textDirection: Directionality.of(context),
    );
    final route = ModalRoute.of(context);
    final box = context.findRenderObject()! as RenderBox;
    final origin = box.localToGlobal(Offset.zero) & box.size;

    bool canShare() => mounted && isCurrent() && route?.isCurrent == true;

    setState(() {
      _sharing = true;
      _failed = false;
    });
    var failed = false;
    try {
      final params = await showDialog<ShareParams>(
        context: context,
        useRootNavigator: false,
        builder: (_) => _LyricShareDialog(
          excerpt: excerpt,
          origin: origin,
          loadArtwork: widget.loadArtwork,
        ),
      );
      if (params != null && canShare()) await SharePlus.instance.share(params);
    } catch (_) {
      failed = canShare();
    } finally {
      if (mounted) {
        setState(() {
          _sharing = false;
          _failed = failed;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FilledButton.tonalIcon(
          key: const ValueKey('music-lyrics-share'),
          onPressed: _sharing || widget.lines.isEmpty ? null : _share,
          icon: const Icon(Icons.share_outlined),
          label: Text(locals.musicLyricsShareLines),
        ),
        if (_failed)
          Semantics(
            liveRegion: true,
            child: Text(locals.musicLyricsShareFailed,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ),
      ],
    );
  }
}

class _LyricShareDialog extends StatefulWidget {
  final MusicLyricShare excerpt;
  final Rect origin;

  final Future<List<File>> Function()? loadArtwork;

  const _LyricShareDialog({
    required this.excerpt,
    required this.origin,
    required this.loadArtwork,
  });

  @override
  State<_LyricShareDialog> createState() => _LyricShareDialogState();
}

class _LyricShareDialogState extends State<_LyricShareDialog> {
  bool _permitted = false;
  MusicLyricSharePalette _palette = MusicLyricSharePalette.violet;
  MusicLyricShareLayout _layout = MusicLyricShareLayout.classic;
  late final Future<ui.Image?> _artwork = _loadArtwork();
  late Future<_LyricImagePreview?> _preview = _renderPreview();
  ui.Image? _decodedArtwork;
  int _previewRevision = 0;

  Future<ui.Image?> _loadArtwork() async {
    final files = await widget.loadArtwork?.call();
    if (files == null) return null;
    for (final file in files) {
      if (!mounted) return null;
      final image = await _decodeArtwork(file);
      if (image == null) continue;
      if (mounted) return _decodedArtwork = image;
      image.dispose();
      return null;
    }
    return null;
  }

  Future<ui.Image?> _decodeArtwork(File file) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          const decodeSize = 384;
          final width = descriptor.width;
          final height = descriptor.height;
          final codec = await descriptor.instantiateCodec(
            targetWidth:
                width >= height && width > decodeSize ? decodeSize : null,
            targetHeight:
                height > width && height > decodeSize ? decodeSize : null,
          );
          try {
            return (await codec.getNextFrame()).image;
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      // Try the next candidate when the file cannot be decoded.
      return null;
    }
  }

  @override
  void dispose() {
    _decodedArtwork?.dispose();
    super.dispose();
  }

  Future<_LyricImagePreview?> _renderPreview() async {
    final revision = ++_previewRevision;
    final artwork = await _artwork;
    if (!mounted || revision != _previewRevision) return null;
    final params = await widget.excerpt.image(
      sharePositionOrigin: widget.origin,
      palette: _palette,
      layout: _layout,
      artwork: artwork,
    );
    final bytes = await params.files!.single.readAsBytes();
    return (params: params, bytes: bytes);
  }

  String _paletteLabel(
      AppLocalizations locals, MusicLyricSharePalette palette) {
    return switch (palette) {
      MusicLyricSharePalette.violet => locals.musicLyricsSharePaletteViolet,
      MusicLyricSharePalette.ocean => locals.musicLyricsSharePaletteOcean,
      MusicLyricSharePalette.forest => locals.musicLyricsSharePaletteForest,
      MusicLyricSharePalette.parchment =>
        locals.musicLyricsSharePaletteParchment,
    };
  }

  String _layoutLabel(AppLocalizations locals, MusicLyricShareLayout layout) =>
      switch (layout) {
        MusicLyricShareLayout.classic => locals.musicLyricsShareLayoutClassic,
        MusicLyricShareLayout.poster => locals.musicLyricsShareLayoutPoster,
        MusicLyricShareLayout.sideBySide =>
          locals.musicLyricsShareLayoutSideBySide,
      };

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PlayerModalBackHandler(
      child: FutureBuilder<_LyricImagePreview?>(
        future: _preview,
        builder: (context, snapshot) {
          final ready = snapshot.connectionState == ConnectionState.done;
          final preview = ready ? snapshot.data : null;
          return AlertDialog(
            scrollable: true,
            title: Text(locals.musicLyricsShareLines),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<MusicLyricShareLayout>(
                  initialValue: _layout,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: locals.musicLyricsShareLayout,
                  ),
                  items: [
                    for (final layout in MusicLyricShareLayout.values)
                      DropdownMenuItem(
                        value: layout,
                        child: Text(_layoutLabel(locals, layout)),
                      ),
                  ],
                  onChanged: (layout) {
                    if (layout == null || layout == _layout) return;
                    setState(() {
                      _layout = layout;
                      _preview = _renderPreview();
                    });
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<MusicLyricSharePalette>(
                  initialValue: _palette,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: locals.musicLyricsSharePalette,
                  ),
                  items: [
                    for (final palette in MusicLyricSharePalette.values)
                      DropdownMenuItem(
                        value: palette,
                        child: Text(_paletteLabel(locals, palette)),
                      ),
                  ],
                  onChanged: (palette) {
                    if (palette == null || palette == _palette) return;
                    setState(() {
                      _palette = palette;
                      _preview = _renderPreview();
                    });
                  },
                ),
                const SizedBox(height: 12),
                if (preview != null)
                  Image.memory(
                    preview.bytes,
                    height: 168,
                    fit: BoxFit.contain,
                    semanticLabel: locals.musicLyricsSharePreview,
                  )
                else
                  SizedBox(
                    height: 168,
                    child: Center(
                      child: Text(ready
                          ? locals.musicLyricsSharePreviewFailed
                          : locals.musicLyricsSharePreviewLoading),
                    ),
                  ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _permitted,
                  onChanged: (value) =>
                      setState(() => _permitted = value ?? false),
                  title: Text(locals.musicLyricsSharePermission),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(locals.cancel),
              ),
              FilledButton.tonal(
                onPressed: _permitted
                    ? () => Navigator.pop(context,
                        widget.excerpt.text(sharePositionOrigin: widget.origin))
                    : null,
                child: Text(locals.musicLyricsShareText),
              ),
              FilledButton.tonal(
                onPressed: _permitted && preview != null
                    ? () => Navigator.pop(context, preview.params)
                    : null,
                child: Text(locals.musicLyricsShareImage),
              ),
            ],
          );
        },
      ),
    );
  }
}
