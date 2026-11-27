import 'package:json_annotation/json_annotation.dart';

part 'dislike.g.dart';

@JsonSerializable()
class Dislike {
  @JsonKey(fromJson: _parseDislikes)
  int? dislikes;

  @JsonKey(fromJson: _parseLikes)
  final int? likes;

  Dislike(this.dislikes, {this.likes});

  static int? _parseDislikes(Object? value) =>
      value is num && value.isFinite ? value.toInt() : null;

  static int? _parseLikes(Object? value) =>
      value is int && value >= 0 ? value : null;

  factory Dislike.fromJson(Map<String, dynamic> json) =>
      _$DislikeFromJson(json);

  Map<String, dynamic> toJson() => _$DislikeToJson(this);
}
