import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/music/services/music_lyric_share.dart';
import 'package:clipious/player/views/components/player_modal_back_handler.dart';
import 'package:clipious/videos/models/music_metadata.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

enum _ShareFormat { text, image }

class MusicLyricShareButton extends StatefulWidget {
  final List<String> lines;
  final MusicMetadata track;
  final String? source;
  final bool edited;
  final bool Function() isCurrent;

  const MusicLyricShareButton({
    super.key,
    required this.lines,
    required this.track,
    required this.source,
    required this.edited,
    required this.isCurrent,
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
      final format = await showDialog<_ShareFormat>(
        context: context,
        useRootNavigator: false,
        builder: (_) => const _LyricShareDialog(),
      );
      if (format == null || !canShare()) return;
      final params = switch (format) {
        _ShareFormat.text => excerpt.text(sharePositionOrigin: origin),
        _ShareFormat.image => await excerpt.image(sharePositionOrigin: origin),
      };
      if (canShare()) await SharePlus.instance.share(params);
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
  const _LyricShareDialog();

  @override
  State<_LyricShareDialog> createState() => _LyricShareDialogState();
}

class _LyricShareDialogState extends State<_LyricShareDialog> {
  bool _permitted = false;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PlayerModalBackHandler(
      child: AlertDialog(
        scrollable: true,
        title: Text(locals.musicLyricsShareLines),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        content: CheckboxListTile(
          value: _permitted,
          onChanged: (value) => setState(() => _permitted = value ?? false),
          title: Text(locals.musicLyricsSharePermission),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel),
          ),
          FilledButton.tonal(
            onPressed: _permitted
                ? () => Navigator.pop(context, _ShareFormat.text)
                : null,
            child: Text(locals.musicLyricsShareText),
          ),
          FilledButton.tonal(
            onPressed: _permitted
                ? () => Navigator.pop(context, _ShareFormat.image)
                : null,
            child: Text(locals.musicLyricsShareImage),
          ),
        ],
      ),
    );
  }
}
