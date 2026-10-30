import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/feedback_report.dart';

class FeedbackSavedState {
  final FeedbackDraft? draft;
  final List<FeedbackReceipt> receipts;
  FeedbackSavedState({this.draft, List<FeedbackReceipt> receipts = const []})
      : receipts = List.unmodifiable(receipts.take(20));

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'draft': draft?.toJson(),
        'receipts': receipts.map((receipt) => receipt.toJson()).toList()
      };

  factory FeedbackSavedState.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 || json['receipts'] is! List) {
      throw const FormatException('Invalid saved feedback');
    }
    final receipts = (json['receipts'] as List).take(20).map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid saved feedback');
      }
      return FeedbackReceipt.fromJson(value);
    }).toList();
    final draft = json['draft'];
    if (draft != null && draft is! Map<String, dynamic>) {
      throw const FormatException('Invalid saved feedback');
    }
    return FeedbackSavedState(
        draft: draft == null
            ? null
            : FeedbackDraft.fromJson(draft as Map<String, dynamic>),
        receipts: receipts);
  }
}

abstract class FeedbackStore {
  Future<FeedbackSavedState> load();
  Future<void> save(FeedbackSavedState state);
}

/// Draft attachments stay in Android's private app data. A write is completed
/// before any network submission, preserving the nonce across app restarts.
class FileFeedbackStore implements FeedbackStore {
  final Future<Directory> Function() directory;
  Future<void> _writes = Future.value();
  FileFeedbackStore({Future<Directory> Function()? directory})
      : directory = directory ?? getApplicationSupportDirectory;

  Future<File> _file() async {
    final parent = Directory(
        '${(await directory()).path}${Platform.pathSeparator}feedback');
    await parent.create(recursive: true);
    return File('${parent.path}${Platform.pathSeparator}state.json');
  }

  @override
  Future<FeedbackSavedState> load() async {
    await _writes;
    final file = await _file();
    if (!await file.exists()) return FeedbackSavedState();
    if (await file.length() > 3 * 1024 * 1024) {
      throw const FormatException('Saved feedback is too large');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid saved feedback');
    }
    return FeedbackSavedState.fromJson(value);
  }

  @override
  Future<void> save(FeedbackSavedState state) {
    final encoded = jsonEncode(state.toJson());
    if (utf8.encode(encoded).length > 3 * 1024 * 1024) {
      return Future.error(const FeedbackFailure('too_large'));
    }
    final result = _writes.catchError((Object _) {}).then((_) async {
      final file = await _file();
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    });
    _writes = result;
    return result;
  }
}
