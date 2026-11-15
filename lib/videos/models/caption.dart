import 'package:json_annotation/json_annotation.dart';

part 'caption.g.dart';

Object? _captionLanguage(Map json, String key) =>
    json[key] ?? json['language_code'];

@JsonSerializable()
class Caption {
  String label;
  @JsonKey(readValue: _captionLanguage)
  String? languageCode;
  String url;

  Caption(this.label, this.languageCode, this.url);

  factory Caption.fromJson(Map<String, dynamic> json) =>
      _$CaptionFromJson(json);

  Map<String, dynamic> toJson() => _$CaptionToJson(this);
}
