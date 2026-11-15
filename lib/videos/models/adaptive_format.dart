import 'package:json_annotation/json_annotation.dart';

part 'adaptive_format.g.dart';

String? _parseSize(Object? value) => value is String ? value : null;

int? _parseFps(Object? value) => switch (value) {
      int() => value,
      String() => int.tryParse(value),
      _ => null,
    };

class AudioTrack {
  final String id;
  final String displayName;
  final bool audioIsDefault;

  const AudioTrack(
      {required this.id,
      required this.displayName,
      this.audioIsDefault = false});

  static AudioTrack? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String) return null;
    final id = json['id'] as String;
    if (id.trim().isEmpty) return null;
    return AudioTrack(
        id: id,
        displayName:
            json['displayName'] is String ? json['displayName'] as String : id,
        audioIsDefault: json['audioIsDefault'] == true);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'audioIsDefault': audioIsDefault,
      };
}

@JsonSerializable(explicitToJson: true)
class AdaptiveFormat {
  String? index;
  String? bitrate;
  String? init;
  String url;
  String itag;
  String type;
  String clen;
  String lmt;
  String projectionType;
  String? container;
  String? encoding;
  String? qualityLabel;
  String? resolution;
  @JsonKey(fromJson: _parseSize)
  String? size;
  @JsonKey(fromJson: _parseFps)
  int? fps;
  @JsonKey(fromJson: AudioTrack.fromJson)
  AudioTrack? audioTrack;

  AdaptiveFormat(
      this.index,
      this.bitrate,
      this.init,
      this.url,
      this.itag,
      this.type,
      this.clen,
      this.lmt,
      this.projectionType,
      this.container,
      this.encoding,
      this.qualityLabel,
      this.resolution,
      {this.size,
      this.fps,
      this.audioTrack});

  factory AdaptiveFormat.fromJson(Map<String, dynamic> json) =>
      _$AdaptiveFormatFromJson(json);

  Map<String, dynamic> toJson() => _$AdaptiveFormatToJson(this);
}
