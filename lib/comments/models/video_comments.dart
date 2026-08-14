import 'package:json_annotation/json_annotation.dart';

import 'comment.dart';

part 'video_comments.g.dart';

@JsonSerializable()
class VideoComments {
  int? commentCount;
  String? videoId;
  String? continuation;
  List<Comment> comments = [];

  VideoComments(
      this.commentCount, this.videoId, this.continuation, this.comments);

  factory VideoComments.fromJson(Map<String, dynamic> json) {
    final normalized = Map<String, dynamic>.from(json);

    if (normalized['comments'] is! List) {
      normalized['comments'] = <Map<String, dynamic>>[];
    }

    return _$VideoCommentsFromJson(normalized);
  }

  Map<String, dynamic> toJson() => _$VideoCommentsToJson(this);
}
