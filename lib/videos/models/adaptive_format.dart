import 'package:json_annotation/json_annotation.dart';

part 'adaptive_format.g.dart';

String? _parseSize(Object? value) => value is String ? value : null;

int? _parseFps(Object? value) => switch (value) {
      int() => value,
      String() => int.tryParse(value),
      _ => null,
    };

@JsonSerializable()
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
      this.fps});

  factory AdaptiveFormat.fromJson(Map<String, dynamic> json) =>
      _$AdaptiveFormatFromJson(json);

  Map<String, dynamic> toJson() => _$AdaptiveFormatToJson(this);
}
