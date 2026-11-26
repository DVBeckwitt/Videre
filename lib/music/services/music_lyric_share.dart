import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:share_plus/share_plus.dart';

enum MusicLyricSharePalette {
  violet(Color(0xff221733), Color(0xfffaf7ff), Color(0xffd7c8ec),
      Color(0xffbb9cf5)),
  ocean(Color(0xff12263a), Color(0xfff3f9ff), Color(0xffd0e5fa),
      Color(0xff7bc2ff)),
  forest(Color(0xff12352a), Color(0xfff4fff5), Color(0xffccedda),
      Color(0xff94d8ad)),
  parchment(Color(0xfffff0d6), Color(0xff361b12), Color(0xff69432d),
      Color(0xffa74424));

  final Color background;
  final Color lyrics;
  final Color attribution;
  final Color accent;

  const MusicLyricSharePalette(
    this.background,
    this.lyrics,
    this.attribution,
    this.accent,
  );
}

enum MusicLyricShareLayout { classic, poster, sideBySide }

class MusicLyricShare {
  static const _width = 1080;
  static const _maxHeight = 2048;
  static const _inset = 80.0;
  static const _top = 116.0;
  static const _attributionGap = 48.0;
  static const _contentWidth = _width - 2 * _inset;

  final String _excerpt;
  final String _attribution;
  final ui.TextDirection _textDirection;

  MusicLyricShare({
    required List<String> lines,
    required String attribution,
    required ui.TextDirection textDirection,
  })  : _excerpt = lines.join('\n'),
        _attribution = attribution,
        _textDirection = textDirection;

  ShareParams text({required ui.Rect sharePositionOrigin}) => ShareParams(
        text: '$_excerpt\n\n$_attribution',
        sharePositionOrigin: sharePositionOrigin,
      );

  Future<ShareParams> image({
    required ui.Rect sharePositionOrigin,
    MusicLyricSharePalette palette = MusicLyricSharePalette.violet,
    MusicLyricShareLayout layout = MusicLyricShareLayout.classic,
    ui.Image? artwork,
  }) async {
    final (picture, height) = _drawCard(palette, layout, artwork);
    try {
      final image = await picture.toImage(_width, height);
      try {
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        if (png == null) throw StateError('Could not encode the lyric image.');
        return ShareParams(
          files: [
            XFile.fromData(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              mimeType: 'image/png',
            ),
          ],
          fileNameOverrides: const ['videre-lyrics.png'],
          sharePositionOrigin: sharePositionOrigin,
        );
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  (ui.Picture, int) _drawCard(
    MusicLyricSharePalette palette,
    MusicLyricShareLayout layout,
    ui.Image? artwork,
  ) {
    const artworkGap = 40.0;
    final artworkSize = artwork == null
        ? 0.0
        : switch (layout) {
            MusicLyricShareLayout.classic => 144.0,
            MusicLyricShareLayout.poster => 256.0,
            MusicLyricShareLayout.sideBySide => 224.0,
          };
    final poster = layout == MusicLyricShareLayout.poster;
    final besideLyrics =
        artwork != null && layout == MusicLyricShareLayout.sideBySide;
    final besideAttribution =
        artwork != null && layout == MusicLyricShareLayout.classic;
    final lyricsIndent = besideLyrics ? artworkSize + artworkGap : 0.0;
    final attributionIndent =
        besideAttribution ? artworkSize + artworkGap : lyricsIndent;
    final lyricsTop =
        _top + (poster && artwork != null ? artworkSize + artworkGap : 0.0);
    final rtl = _textDirection == ui.TextDirection.rtl;
    final alignment = poster ? ui.TextAlign.center : ui.TextAlign.start;
    final excerpt = TextPainter(
      textDirection: _textDirection,
      textAlign: alignment,
      maxLines: 64,
    );
    final attribution = TextPainter(
      textDirection: _textDirection,
      textAlign: alignment,
      maxLines: 72,
    );
    try {
      for (final scale in [1.0, 0.9, 0.8, 0.7, 0.6]) {
        excerpt.text = TextSpan(
          text: _excerpt,
          style: TextStyle(
            color: palette.lyrics,
            fontSize: 52 * scale,
            fontWeight: FontWeight.w600,
            height: 1.24,
          ),
        );
        attribution.text = TextSpan(
          text: _attribution,
          style: TextStyle(
            color: palette.attribution,
            fontSize: 34 * scale,
            height: 1.3,
          ),
        );
        final lyricsWidth = _contentWidth - lyricsIndent;
        final attributionWidth = _contentWidth - attributionIndent;
        excerpt.layout(minWidth: lyricsWidth, maxWidth: lyricsWidth);
        attribution.layout(
          minWidth: attributionWidth,
          maxWidth: attributionWidth,
        );
        final attributionTop = lyricsTop + excerpt.height + _attributionGap;
        final artworkTop = besideAttribution ? attributionTop : _top;
        final height = (math.max(attributionTop + attribution.height,
                    artworkTop + artworkSize) +
                _inset)
            .ceil();
        if (height > _maxHeight ||
            excerpt.didExceedMaxLines ||
            attribution.didExceedMaxLines) {
          continue;
        }

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(palette.background, ui.BlendMode.src);
        final accent = switch (layout) {
          MusicLyricShareLayout.classic =>
            ui.Rect.fromLTWH(rtl ? _width - _inset - 96 : _inset, 72, 96, 8),
          MusicLyricShareLayout.poster =>
            const ui.Rect.fromLTWH((_width - 96) / 2, 72, 96, 8),
          MusicLyricShareLayout.sideBySide =>
            ui.Rect.fromLTWH(rtl ? _width - _inset - 8 : _inset, 66, 8, 24),
        };
        canvas.drawRRect(
          ui.RRect.fromRectAndRadius(accent, const ui.Radius.circular(4)),
          ui.Paint()..color = palette.accent,
        );
        if (artwork != null) {
          final artworkLeft = poster
              ? (_width - artworkSize) / 2
              : (rtl ? _width - _inset - artworkSize : _inset);
          paintImage(
            canvas: canvas,
            rect: ui.Rect.fromLTWH(
                artworkLeft, artworkTop, artworkSize, artworkSize),
            image: artwork,
            fit: BoxFit.cover,
            filterQuality: ui.FilterQuality.medium,
          );
        }
        excerpt.paint(
          canvas,
          ui.Offset(_inset + (rtl ? 0 : lyricsIndent), lyricsTop),
        );
        attribution.paint(
          canvas,
          ui.Offset(_inset + (rtl ? 0 : attributionIndent), attributionTop),
        );
        return (recorder.endRecording(), height);
      }
      throw StateError('The lyric excerpt is too long for an image.');
    } finally {
      excerpt.dispose();
      attribution.dispose();
    }
  }
}
