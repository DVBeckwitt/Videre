/// Properties read from the audio stream in an inspected file.
class MusicFileAudioFormat {
  const MusicFileAudioFormat._(
    this.codecMimeType,
    this.bitrateBps,
    this.sampleRateHz,
  );

  final String? codecMimeType;
  final int? bitrateBps;
  final int? sampleRateHz;

  static final _audioMimeType = RegExp(
    r'^audio/[a-zA-Z0-9][a-zA-Z0-9.+_-]{0,63}$',
  );

  static MusicFileAudioFormat? fromChannel(Object? value) {
    if (value is! Map) return null;
    final mime = value['codecMimeType'];
    final codecMimeType =
        mime is String && _audioMimeType.stringMatch(mime) == mime
            ? mime.toLowerCase()
            : null;
    final bitrate = value['bitrateBps'];
    final bitrateBps = bitrate is int && bitrate > 0 ? bitrate : null;
    final sampleRate = value['sampleRateHz'];
    final sampleRateHz =
        sampleRate is int && sampleRate > 0 ? sampleRate : null;
    if (codecMimeType == null && bitrateBps == null && sampleRateHz == null) {
      return null;
    }
    return MusicFileAudioFormat._(codecMimeType, bitrateBps, sampleRateHz);
  }

  String? get codec => switch (codecMimeType) {
        'audio/mpeg' => 'MP3',
        'audio/mpeg-l1' => 'MP1',
        'audio/mpeg-l2' => 'MP2',
        'audio/mp4a-latm' => 'AAC',
        'audio/flac' => 'FLAC',
        'audio/opus' => 'Opus',
        'audio/vorbis' => 'Vorbis',
        'audio/alac' => 'ALAC',
        'audio/raw' => 'PCM',
        _ => codecMimeType,
      };
}
