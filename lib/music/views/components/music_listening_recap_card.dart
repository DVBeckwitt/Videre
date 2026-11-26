import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../main.dart' show isTv;
import '../../../player/views/components/player_modal_back_handler.dart';
import '../../../utils.dart' show selectKeys;
import '../../models/music_listening_rankings.dart';
import '../../models/music_listening_recap.dart';

String musicRecapPeriodLabel(
  MaterialLocalizations dates,
  MusicListeningRecapPeriod period,
) {
  final month = period.month;
  return month == null
      ? dates.formatYear(DateTime.utc(period.year))
      : dates.formatMonthYear(DateTime.utc(period.year, month));
}

String musicRecapSummary(AppLocalizations locals, MusicListeningRecap recap) =>
    locals.musicListeningSummary(
      locals.musicListeningPlayCount(recap.rankings.plays),
      locals.musicTrackCount(recap.songCount),
    );

String musicRecapRecordedDates(
  MaterialLocalizations dates,
  AppLocalizations locals,
  MusicListeningRecap recap,
) =>
    DateUtils.isSameDay(recap.firstPlay, recap.lastPlay)
        ? locals.musicListeningRecapRecordedOn(
            dates.formatFullDate(recap.firstPlay))
        : locals.musicListeningRecapRecordedBetween(
            dates.formatFullDate(recap.firstPlay),
            dates.formatFullDate(recap.lastPlay));

class MusicListeningRecapCardDialog extends StatefulWidget {
  const MusicListeningRecapCardDialog({
    super.key,
    required this.recap,
    required this.canShare,
  });

  final MusicListeningRecap? recap;
  final bool Function(MusicListeningRecap) canShare;

  @override
  State<MusicListeningRecapCardDialog> createState() =>
      _MusicListeningRecapCardDialogState();
}

class _MusicListeningRecapCardDialogState
    extends State<MusicListeningRecapCardDialog> {
  final _cardKey = GlobalKey();
  bool _sharing = false;
  bool _failed = false;

  Future<void> _share(BuildContext buttonContext) async {
    final recap = widget.recap;
    final route = ModalRoute.of(context);
    if (_sharing || recap == null || route?.isCurrent != true) return;

    setState(() {
      _sharing = true;
      _failed = false;
    });
    var failed = false;
    try {
      if (!widget.canShare(recap)) {
        failed = true;
        return;
      }
      final button = buttonContext.findRenderObject()! as RenderBox;
      final origin = button.localToGlobal(Offset.zero) & button.size;
      final card =
          _cardKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await card.toImage(
        pixelRatio: math.min(1080 / card.size.width, 1920 / card.size.height),
      );
      final ByteData? png;
      try {
        png = await image.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        image.dispose();
      }
      if (!mounted || route?.isCurrent != true || widget.recap == null) return;
      if (png == null || !widget.canShare(recap)) {
        failed = true;
        return;
      }
      final fileName = 'videre-music-recap-${recap.period.fileSuffix}.png';
      final result = await SharePlus.instance.share(ShareParams(
        files: [
          XFile.fromData(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
            mimeType: 'image/png',
          ),
        ],
        fileNameOverrides: [fileName],
        sharePositionOrigin: origin,
        downloadFallbackEnabled: false,
      ));
      failed = result.status == ShareResultStatus.unavailable;
    } catch (_) {
      failed = true;
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
    final recap = widget.recap;
    return PlayerModalBackHandler(
      child: Shortcuts(
        shortcuts: {
          for (final key in selectKeys)
            SingleActivator(key): const ActivateIntent(),
        },
        child: AlertDialog(
          scrollable: true,
          title: Text(locals.musicListeningRecapCardPreview),
          content: recap == null
              ? Text(locals.musicListeningRecapCardUnavailable)
              : SizedBox(
                  width: 400,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Focus(
                        skipTraversal: true,
                        child: Builder(
                          builder: (context) => DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              border: Focus.of(context).hasFocus
                                  ? Border.all(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      width: 3,
                                    )
                                  : null,
                            ),
                            child: RepaintBoundary(
                              key: _cardKey,
                              child: _RecapCard(recap: recap),
                            ),
                          ),
                        ),
                      ),
                      if (_failed)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              locals.musicListeningRecapCardShareFailed,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
          actions: [
            TextButton(
              autofocus: isTv,
              onPressed: () => Navigator.of(context).pop(),
              child: Text(locals.cancel),
            ),
            if (recap != null)
              Builder(
                builder: (context) => FilledButton.icon(
                  onPressed: _sharing ? null : () => _share(context),
                  icon: const Icon(Icons.share_outlined),
                  label: Text(locals.musicListeningRecapCardShare),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecapCard extends StatelessWidget {
  const _RecapCard({required this.recap});

  final MusicListeningRecap recap;

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final dates = MaterialLocalizations.of(context);
    final topSong = recap.highlights(MusicListeningRankBy.song).first;
    final topArtist =
        recap.highlights(MusicListeningRankBy.artist).firstOrNull?.title;
    const foreground = Color(0xfffaf7ff);
    const muted = Color(0xffe1d6f3);
    const accent = Color(0xffd6b8ff);
    const labelStyle =
        TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w600);
    const titleStyle =
        TextStyle(color: foreground, fontSize: 18, fontWeight: FontWeight.w700);

    // Directional focus scrolls each part of a tall card into view on TV.
    Widget section(List<Widget> children) => Focus(
          canRequestFocus: isTv,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        );

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff392462), Color(0xff19132f)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            section([
              Text(locals.musicListeningRecapCardBrand, style: labelStyle),
              Semantics(
                header: true,
                child: Text(
                  musicRecapPeriodLabel(dates, recap.period),
                  style: const TextStyle(
                    color: foreground,
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(musicRecapSummary(locals, recap), style: titleStyle),
            ]),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(color: Color(0xff8a72af), height: 1),
            ),
            section([
              Text(locals.musicListeningRecapTopSong, style: labelStyle),
              Text(
                topSong.title ?? locals.musicListeningUnknownTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              if (topArtist != null) ...[
                const SizedBox(height: 10),
                Text(locals.musicListeningRecapTopArtist, style: labelStyle),
                Text(
                  topArtist,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ],
            ]),
            const SizedBox(height: 16),
            section([
              Text(
                musicRecapRecordedDates(dates, locals, recap),
                style: const TextStyle(color: muted, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                locals.musicListeningRecapCoverage,
                style: const TextStyle(color: muted, fontSize: 13),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
