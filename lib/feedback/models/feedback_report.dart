import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../services/feedback_diagnostics.dart';

enum FeedbackKind { bug, suggestion }

const feedbackTitleLimit = 120;
const feedbackDescriptionLimit = 8000;
const feedbackScreenshotLimit = 2 * 1024 * 1024;
final _submissionIdPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// Only explicitly selected, previewable fields cross the feedback boundary.
class FeedbackDraft {
  final String submissionId;
  final FeedbackKind kind;
  final String title;
  final String description;
  final Map<String, Object>? diagnostics;
  final Uint8List? _screenshot;
  Uint8List? get screenshot =>
      _screenshot == null ? null : Uint8List.fromList(_screenshot!);
  final bool attempted;

  FeedbackDraft(
      {required this.submissionId,
      this.kind = FeedbackKind.bug,
      this.title = '',
      this.description = '',
      Map<String, Object>? diagnostics,
      Uint8List? screenshot,
      this.attempted = false})
      : diagnostics = diagnostics == null
            ? null
            : Map.unmodifiable(sanitizeFeedbackDiagnostics(diagnostics)),
        _screenshot =
            screenshot == null ? null : Uint8List.fromList(screenshot);

  factory FeedbackDraft.empty() =>
      FeedbackDraft(submissionId: const Uuid().v4());

  bool get includeDiagnostics => diagnostics != null;
  bool get isEmpty =>
      title.isEmpty && description.isEmpty && _screenshot == null;
  bool get isValid =>
      _submissionIdPattern.hasMatch(submissionId) &&
      title.trim().isNotEmpty &&
      title.length <= feedbackTitleLimit &&
      description.trim().isNotEmpty &&
      description.length <= feedbackDescriptionLimit &&
      (_screenshot == null || validFeedbackScreenshot(_screenshot!));

  FeedbackDraft copyWith(
          {FeedbackKind? kind,
          String? title,
          String? description,
          Map<String, Object>? diagnostics,
          bool clearDiagnostics = false,
          Uint8List? screenshot,
          bool clearScreenshot = false,
          bool? attempted}) =>
      FeedbackDraft(
          submissionId: submissionId,
          kind: kind ?? this.kind,
          title: title ?? this.title,
          description: description ?? this.description,
          diagnostics:
              clearDiagnostics ? null : diagnostics ?? this.diagnostics,
          screenshot: clearScreenshot ? null : screenshot ?? _screenshot,
          attempted: attempted ?? this.attempted);

  Map<String, Object> toRequest() => {
        'schemaVersion': 1,
        'submissionId': submissionId,
        'kind': kind.name,
        'title': title,
        'description': description,
        if (diagnostics != null) 'diagnostics': diagnostics!,
        if (_screenshot != null)
          'screenshot': {
            'mimeType': 'image/png',
            'base64': base64Encode(_screenshot!)
          },
      };
  Map<String, Object> toJson() => {...toRequest(), 'attempted': attempted};

  factory FeedbackDraft.fromJson(Map<String, dynamic> json) {
    final id = json['submissionId'],
        kind = json['kind'],
        title = json['title'],
        description = json['description'];
    if (id is! String ||
        !_submissionIdPattern.hasMatch(id) ||
        !['bug', 'suggestion'].contains(kind) ||
        title is! String ||
        title.length > feedbackTitleLimit ||
        description is! String ||
        description.length > feedbackDescriptionLimit) {
      throw const FormatException('Invalid saved feedback');
    }
    Uint8List? screenshot;
    if (json['screenshot'] != null) {
      final value = json['screenshot'];
      if (value is! Map ||
          value['mimeType'] != 'image/png' ||
          value['base64'] is! String ||
          (value['base64'] as String).length > 2800000) {
        throw const FormatException('Invalid saved screenshot');
      }
      screenshot = base64Decode(value['base64'] as String);
      if (!validFeedbackScreenshot(screenshot)) {
        throw const FormatException('Invalid saved screenshot');
      }
    }
    final rawDiagnostics = json['diagnostics'];
    return FeedbackDraft(
        submissionId: id,
        kind: kind == 'suggestion' ? FeedbackKind.suggestion : FeedbackKind.bug,
        title: title,
        description: description,
        diagnostics: rawDiagnostics is Map<String, dynamic>
            ? sanitizeFeedbackDiagnostics(rawDiagnostics)
            : null,
        screenshot: screenshot,
        attempted: json['attempted'] == true);
  }
}

bool validFeedbackScreenshot(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 || bytes.length > feedbackScreenshotLimit) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(8) != 13) return false;
  const headerType = [73, 72, 68, 82];
  for (var i = 0; i < headerType.length; i++) {
    if (bytes[12 + i] != headerType[i]) return false;
  }
  final width = data.getUint32(16), height = data.getUint32(20);
  return width > 0 && height > 0 && width <= 4096 && height <= 4096;
}

class FeedbackReceipt {
  final String submissionId;
  final int issueNumber;
  final Uri issueUrl;
  final DateTime createdAt;
  final String title;
  final FeedbackKind kind;
  const FeedbackReceipt(
      {required this.submissionId,
      required this.issueNumber,
      required this.issueUrl,
      required this.createdAt,
      required this.title,
      required this.kind});

  static bool validIssueUrl(Uri uri, int issueNumber) =>
      issueNumber > 0 &&
      uri.scheme == 'https' &&
      uri.host == 'github.com' &&
      (!uri.hasPort || uri.port == 443) &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.path == '/DVBeckwitt/Videre/issues/$issueNumber';

  Map<String, Object> toJson() => {
        'submissionId': submissionId,
        'issueNumber': issueNumber,
        'issueUrl': issueUrl.toString(),
        'createdAt': createdAt.toUtc().toIso8601String(),
        'title': title,
        'kind': kind.name
      };

  factory FeedbackReceipt.fromJson(Map<String, dynamic> json) {
    final id = json['submissionId'],
        number = json['issueNumber'],
        url = json['issueUrl'],
        date = json['createdAt'],
        title = json['title'],
        kind = json['kind'];
    if (id is! String ||
        !_submissionIdPattern.hasMatch(id) ||
        number is! int ||
        url is! String ||
        date is! String ||
        title is! String ||
        title.length > feedbackTitleLimit ||
        !['bug', 'suggestion'].contains(kind)) {
      throw const FormatException('Invalid saved feedback receipt');
    }
    final uri = Uri.parse(url);
    if (!validIssueUrl(uri, number)) {
      throw const FormatException('Invalid saved issue URL');
    }
    return FeedbackReceipt(
        submissionId: id,
        issueNumber: number,
        issueUrl: uri,
        createdAt: DateTime.parse(date),
        title: title,
        kind:
            kind == 'suggestion' ? FeedbackKind.suggestion : FeedbackKind.bug);
  }
}

/// Fixed error codes only: transport messages/bodies may contain private data.
class FeedbackFailure implements Exception {
  final String code;
  final int? retryAfterSeconds;
  const FeedbackFailure(this.code, {this.retryAfterSeconds});
  @override
  String toString() => 'FeedbackFailure($code)';
}
