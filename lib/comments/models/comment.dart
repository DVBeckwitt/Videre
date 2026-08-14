import 'package:clipious/comments/models/comment_replies.dart';
import 'package:clipious/comments/models/creator_heart.dart';
import 'package:json_annotation/json_annotation.dart';

import '../../utils/models/image_object.dart';

part 'comment.g.dart';

@JsonSerializable()
class Comment {
  String author;
  List<ImageObject> authorThumbnails = [];
  String authorId;
  String authorUrl;
  bool isEdited;
  String content;
  String publishedText;
  int likeCount;
  String commentId;
  bool authorIsChannelOwner = false;
  CreatorHeart? creatorHeart;
  CommentReplies? replies;

  Comment(
      this.author,
      this.authorThumbnails,
      this.authorId,
      this.authorUrl,
      this.isEdited,
      this.content,
      this.publishedText,
      this.likeCount,
      this.commentId,
      this.authorIsChannelOwner,
      this.creatorHeart,
      this.replies);

  factory Comment.fromJson(Map<String, dynamic> json) {
    final normalized = Map<String, dynamic>.from(json);

    if (normalized['authorThumbnails'] is! List) {
      final thumbnail = normalized['authorThumbnail'];

      normalized['authorThumbnails'] =
          thumbnail is String && thumbnail.isNotEmpty
              ? <Map<String, dynamic>>[
                  <String, dynamic>{
                    'url': thumbnail,
                    'width': 0,
                    'height': 0,
                  },
                ]
              : <Map<String, dynamic>>[];
    }

    return _$CommentFromJson(normalized);
  }

  Map<String, dynamic> toJson() => _$CommentToJson(this);
}
