import 'dart:ui' as ui;

import 'package:clipious/music/services/music_lyric_share.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const origin = ui.Rect.fromLTWH(20, 40, 80, 40);
  const lyrics = ['تشرق الشمس', 'Café e chuva 🎶'];
  const attribution = 'أغنية — مؤدٍ\nSource: LRCLIB';

  MusicLyricShare excerpt(List<String> lines) => MusicLyricShare(
        lines: lines,
        attribution: attribution,
        textDirection: ui.TextDirection.rtl,
      );

  test('text preserves the selected lines and attribution', () {
    final payload = excerpt(lyrics).text(sharePositionOrigin: origin);

    expect(payload.text, '${lyrics.join('\n')}\n\n$attribution');
    expect(payload.sharePositionOrigin, origin);
  });

  test('image is a bounded PNG with a native share anchor', () async {
    final payload = await excerpt(lyrics).image(sharePositionOrigin: origin);

    expect(payload.sharePositionOrigin, origin);
    expect(payload.fileNameOverrides, ['videre-lyrics.png']);
    final file = payload.files!.single;
    expect(file.mimeType, 'image/png');
    final bytes = await file.readAsBytes();
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);

    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        expect(frame.image.width, 1080);
        expect(frame.image.height, inInclusiveRange(1, 2048));
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });

  test('an oversized image can still be shared as text', () async {
    final lines = List.filled(40, 'Example lyric');
    final share = excerpt(lines);

    await expectLater(
      share.image(sharePositionOrigin: origin),
      throwsA(isA<StateError>()),
    );
    expect(
      share.text(sharePositionOrigin: origin).text,
      '${lines.join('\n')}\n\n$attribution',
    );
  });
}
