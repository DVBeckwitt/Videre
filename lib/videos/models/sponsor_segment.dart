import 'package:clipious/videos/models/sponsor_segment_types.dart';
import 'package:json_annotation/json_annotation.dart';

part 'sponsor_segment.g.dart';

@JsonSerializable()
class SponsorSegment {
  String actionType;
  List<double> segment;
  SponsorSegmentType category;

  SponsorSegment(this.actionType, this.segment, this.category);

  factory SponsorSegment.fromJson(Map<String, dynamic> json) =>
      _$SponsorSegmentFromJson(json);

  Map<String, dynamic> toJson() => _$SponsorSegmentToJson(this);
}
