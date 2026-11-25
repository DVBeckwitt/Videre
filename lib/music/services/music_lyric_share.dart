import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:share_plus/share_plus.dart';

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

  Future<ShareParams> image({required ui.Rect sharePositionOrigin}) async {
    final (picture, height) = _drawCard();
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

  (ui.Picture, int) _drawCard() {
    final excerpt = TextPainter(
      text: TextSpan(
        text: _excerpt,
        style: const TextStyle(
          color: Color(0xfffaf7ff),
          fontSize: 52,
          fontWeight: FontWeight.w600,
          height: 1.24,
        ),
      ),
      textDirection: _textDirection,
      maxLines: 32,
    );
    final attribution = TextPainter(
      text: TextSpan(
        text: _attribution,
        style: const TextStyle(
          color: Color(0xffd7c8ec),
          fontSize: 34,
          height: 1.3,
        ),
      ),
      textDirection: _textDirection,
      maxLines: 44,
    );
    try {
      excerpt.layout(minWidth: _contentWidth, maxWidth: _contentWidth);
      attribution.layout(minWidth: _contentWidth, maxWidth: _contentWidth);
      final attributionTop = _top + excerpt.height + _attributionGap;
      final height = (attributionTop + attribution.height + _inset).ceil();
      if (height > _maxHeight ||
          excerpt.didExceedMaxLines ||
          attribution.didExceedMaxLines) {
        throw StateError('The lyric excerpt is too long for an image.');
      }

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawColor(const Color(0xff221733), ui.BlendMode.src);
      const accentWidth = 96.0;
      final accentLeft = _textDirection == ui.TextDirection.rtl
          ? _width - _inset - accentWidth
          : _inset;
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromLTWH(accentLeft, 72, accentWidth, 8),
          const ui.Radius.circular(4),
        ),
        ui.Paint()..color = const Color(0xffbb9cf5),
      );
      excerpt.paint(canvas, const ui.Offset(_inset, _top));
      attribution.paint(canvas, ui.Offset(_inset, attributionTop));
      return (recorder.endRecording(), height);
    } finally {
      excerpt.dispose();
      attribution.dispose();
    }
  }
}
