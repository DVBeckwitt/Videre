import '../../videos/models/adaptive_format.dart';

/// An instance-advertised representation. Signed stream URLs stay in the
/// decoder and are never part of the chooser or a saved preference.
typedef MusicAudioQuality = ({
  String itag,
  int bitrate,
  String codec,
  String? trackId,
});

MusicAudioQuality? musicAudioQualityOf(AdaptiveFormat format) {
  final bitrate = int.tryParse(format.bitrate ?? '');
  if (bitrate == null || bitrate <= 0 || format.itag.isEmpty) return null;
  final mime = format.type.split(';').first.trim();
  final encoding = format.encoding?.trim();
  return (
    itag: format.itag,
    bitrate: bitrate,
    codec: encoding == null || encoding.isEmpty ? mime : encoding,
    trackId: format.audioTrack?.id,
  );
}

/// Published by the active decoder after it has admitted the source.
class MusicAudioQualityMenu {
  final String videoId;
  final List<MusicAudioQuality> choices;
  final MusicAudioQuality? selected;
  final MusicAudioQuality? effective;
  final bool saved;
  final Future<bool> Function(MusicAudioQuality?) select;

  const MusicAudioQualityMenu({
    required this.videoId,
    required this.choices,
    required this.selected,
    required this.effective,
    required this.saved,
    required this.select,
  });
}
