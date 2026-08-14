import 'package:clipious/comments/models/comment.dart';
import 'package:clipious/comments/models/video_comments.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Comment.fromJson', () {
    test('parses the legacy authorThumbnails list unchanged', () {
      final authorThumbnails = <Map<String, dynamic>>[
        <String, dynamic>{
          'url': 'https://example.com/legacy.jpg',
          'width': 88,
          'height': 88,
        },
      ];
      final json = _commentJson(
        authorThumbnails: authorThumbnails,
      );

      final comment = Comment.fromJson(json);

      expect(comment.authorThumbnails, hasLength(1));
      expect(comment.authorThumbnails.single.url,
          'https://example.com/legacy.jpg');
      expect(comment.authorThumbnails.single.width, 88);
      expect(comment.authorThumbnails.single.height, 88);
      expect(json['authorThumbnails'], same(authorThumbnails));
      expect(json, isNot(contains('authorThumbnail')));
    });

    test('normalizes the new authorThumbnail string without mutating input',
        () {
      final json = _commentJson(
        authorThumbnail: 'https://example.com/new.jpg',
      );

      final comment = Comment.fromJson(json);

      expect(comment.authorThumbnails, hasLength(1));
      expect(
          comment.authorThumbnails.single.url, 'https://example.com/new.jpg');
      expect(comment.authorThumbnails.single.width, 0);
      expect(comment.authorThumbnails.single.height, 0);
      expect(json, isNot(contains('authorThumbnails')));
    });

    test('uses an empty thumbnail list when thumbnail fields are missing', () {
      final json = _commentJson();

      final comment = Comment.fromJson(json);

      expect(comment.authorThumbnails, isEmpty);
      expect(json, isNot(contains('authorThumbnails')));
    });
  });

  group('VideoComments.fromJson', () {
    test('uses an empty comments list when comments is null', () {
      final json = <String, dynamic>{'comments': null};

      final comments = VideoComments.fromJson(json);

      expect(comments.comments, isEmpty);
      expect(json['comments'], isNull);
    });

    test('uses an empty comments list when comments is missing', () {
      final json = <String, dynamic>{};

      final comments = VideoComments.fromJson(json);

      expect(comments.comments, isEmpty);
      expect(json, isNot(contains('comments')));
    });
  });
}

Map<String, dynamic> _commentJson({
  List<Map<String, dynamic>>? authorThumbnails,
  String? authorThumbnail,
}) {
  return <String, dynamic>{
    'author': 'Author',
    if (authorThumbnails != null) 'authorThumbnails': authorThumbnails,
    if (authorThumbnail != null) 'authorThumbnail': authorThumbnail,
    'authorId': 'author-id',
    'authorUrl': '/channel/author-id',
    'isEdited': false,
    'content': 'Comment text',
    'publishedText': 'now',
    'likeCount': 1,
    'commentId': 'comment-id',
    'authorIsChannelOwner': false,
    'creatorHeart': null,
    'replies': null,
  };
}
