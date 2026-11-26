import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../services/local_music_video_pairings.dart';

enum _PairingAction { replace, offset, remove }

Future<void> showLocalMusicVideoPairing(
    BuildContext context, LocalMusicVideoOwner owner,
    {required bool Function() isCurrent}) async {
  final pairing = await LocalMusicVideoPairings.get(owner);
  if (!context.mounted || !isCurrent()) return;
  if (pairing == null) {
    await LocalMusicVideoPairings.pick(owner);
    return;
  }

  final locals = AppLocalizations.of(context)!;
  final action = await showDialog<_PairingAction>(
    context: context,
    useRootNavigator: false,
    builder: (context) => PlayerModalBackHandler(
      child: SimpleDialog(
        title: Text(locals.localMusicPairedVideo),
        children: [
          if (pairing.name.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(pairing.name,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _PairingAction.offset),
            child: Text(locals.localMusicVideoOffset),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _PairingAction.replace),
            child: Text(locals.localMusicReplaceVideo),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, _PairingAction.remove),
            child: Text(locals.localMusicRemoveVideo),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || !isCurrent()) return;
  switch (action) {
    case _PairingAction.replace:
      await LocalMusicVideoPairings.pick(owner);
    case _PairingAction.offset:
      final offset = await showDialog<Duration>(
        context: context,
        useRootNavigator: false,
        builder: (_) => _VideoOffsetDialog(pairing.offset),
      );
      if (offset != null && context.mounted && isCurrent()) {
        await LocalMusicVideoPairings.setOffset(owner, pairing, offset);
      }
    case _PairingAction.remove:
      await LocalMusicVideoPairings.remove(owner, pairing);
    case null:
      break;
  }
}

class _VideoOffsetDialog extends StatefulWidget {
  const _VideoOffsetDialog(this.initial);

  final Duration initial;

  @override
  State<_VideoOffsetDialog> createState() => _VideoOffsetDialogState();
}

class _VideoOffsetDialogState extends State<_VideoOffsetDialog> {
  static final _decimalSeconds =
      RegExp(r'^[+-]?(?:\d+(?:[.,]\d{0,3})?|[.,]\d{1,3})$');
  late final _text = TextEditingController(
      text: (widget.initial.inMilliseconds / 1000)
          .toStringAsFixed(3)
          .replaceFirst(RegExp(r'\.?0+$'), ''));
  bool _invalid = false;

  void _save() {
    final input = _text.text.trim();
    final seconds = _decimalSeconds.hasMatch(input)
        ? double.tryParse(input.replaceAll(',', '.'))
        : null;
    if (seconds == null ||
        seconds.abs() > LocalMusicVideoPairing.maxOffset.inSeconds) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, Duration(milliseconds: (seconds * 1000).round()));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    return PlayerModalBackHandler(
      child: AlertDialog(
        scrollable: true,
        title: Text(locals.localMusicVideoOffset),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(locals.localMusicVideoOffsetHelp),
            TextField(
              controller: _text,
              keyboardType: const TextInputType.numberWithOptions(
                  signed: true, decimal: true),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: locals.localMusicVideoOffsetSeconds,
                errorText:
                    _invalid ? locals.localMusicVideoOffsetInvalid : null,
                errorMaxLines: 3,
              ),
              onChanged: (_) {
                if (_invalid) setState(() => _invalid = false);
              },
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(locals.cancel),
          ),
          FilledButton(onPressed: _save, child: Text(locals.save)),
        ],
      ),
    );
  }
}
