import 'package:json_annotation/json_annotation.dart';

part 'format_stream.g.dart';

@JsonSerializable()
class FormatStream {
  String url;
  String itag;
  String type;
  String quality;
  String? container;
  String? encoding;
  String? qualityLabel;
  String? resolution;
  String? size;

  FormatStream(this.url, this.itag, this.type, this.quality, this.container,
      this.encoding, this.qualityLabel, this.resolution, this.size);

  /// The retired combined 720p stream can still appear in instance metadata.
  /// Adaptive 720p video is represented by AdaptiveFormat, not this format.
  @JsonKey(includeFromJson: false, includeToJson: false)
  bool get isLegacyHd720 =>
      itag.trim() == '22' || quality.trim().toLowerCase() == 'hd720';

  factory FormatStream.fromJson(Map<String, dynamic> json) =>
      _$FormatStreamFromJson(json);

  Map<String, dynamic> toJson() => _$FormatStreamToJson(this);
}
