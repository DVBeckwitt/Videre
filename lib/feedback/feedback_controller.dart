import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models/feedback_report.dart';
import 'services/feedback_diagnostics.dart';
import 'services/feedback_store.dart';
import 'services/feedback_submission_client.dart';

/// Owns a user-reviewed draft. No request is made until submit is called.
class FeedbackController extends ChangeNotifier {
  final FeedbackSubmissionClient client;
  final FeedbackStore store;
  final Future<Map<String, Object>> Function() collectDiagnostics;
  FeedbackDraft _draft = FeedbackDraft.empty();
  List<FeedbackReceipt> _receipts = const [];
  FeedbackFailure? _error;
  bool _loading = true;
  bool _busy = false;
  bool _disposed = false;
  bool _loadFailed = false;
  Future<void>? _initialization;
  Completer<void>? _activeOperation;
  Future<void> _saves = Future.value();
  Timer? _saveTimer;

  FeedbackController(
      {FeedbackSubmissionClient? client,
      FeedbackStore? store,
      Future<Map<String, Object>> Function()? collectDiagnostics})
      : client = client ?? FeedbackSubmissionClient(),
        store = store ?? FileFeedbackStore(),
        collectDiagnostics = collectDiagnostics ?? collectFeedbackDiagnostics;

  FeedbackDraft get draft => _draft;
  List<FeedbackReceipt> get receipts => List.unmodifiable(_receipts);
  FeedbackFailure? get error => _error;
  bool get loading => _loading;
  bool get loadFailed => _loadFailed;
  bool get busy => _busy;
  bool get locked => _draft.attempted;
  bool get configured => client.configured;

  /// The owning route keeps its reentry guard until any submitted snapshot has
  /// finished writing. Disposing UI must not race a newer draft on disk.
  Future<void> waitUntilIdle() => _activeOperation?.future ?? Future.value();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      final state = await store.load();
      if (_disposed) return;
      _draft = state.draft ?? FeedbackDraft.empty();
      _receipts = state.receipts;
      if (_draft.attempted) _error = const FeedbackFailure('pending');
    } catch (_) {
      // Do not overwrite an unreadable pending submission: its identifier is
      // required to prevent a duplicate after a previous interrupted send.
      _loadFailed = true;
      _error = const FeedbackFailure('storage');
    } finally {
      _loading = false;
      _notify();
    }
  }

  void update({FeedbackKind? kind, String? title, String? description}) {
    if (_disposed || loading || busy || locked || _loadFailed) return;
    if ((title?.length ?? 0) > feedbackTitleLimit ||
        (description?.length ?? 0) > feedbackDescriptionLimit) {
      _error = const FeedbackFailure('validation');
      _notify();
      return;
    }
    _draft =
        _draft.copyWith(kind: kind, title: title, description: description);
    _error = null;
    _scheduleSave();
    _notify();
  }

  Future<void> setIncludeDiagnostics(bool enabled) async {
    if (_disposed || loading || busy || locked || _loadFailed) return;
    if (!enabled) {
      _draft = _draft.copyWith(clearDiagnostics: true);
      _error = null;
      _scheduleSave();
      _notify();
      return;
    }
    _busy = true;
    _activeOperation = Completer<void>();
    _error = null;
    _notify();
    try {
      final value = await collectDiagnostics();
      if (_disposed) return;
      _draft = _draft.copyWith(diagnostics: sanitizeFeedbackDiagnostics(value));
      _scheduleSave();
    } catch (_) {
      _error = const FeedbackFailure('diagnostics');
    } finally {
      _busy = false;
      _activeOperation?.complete();
      _activeOperation = null;
      _notify();
    }
  }

  Future<void> setScreenshot(Uint8List? screenshot) async {
    if (_disposed || loading || busy || locked || _loadFailed) return;
    if (screenshot != null && !validFeedbackScreenshot(screenshot)) {
      _error = FeedbackFailure(screenshot.length > feedbackScreenshotLimit
          ? 'too_large'
          : 'screenshot');
      _notify();
      return;
    }
    _draft = _draft.copyWith(
        screenshot: screenshot, clearScreenshot: screenshot == null);
    _error = null;
    _scheduleSave();
    _notify();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), () {
      unawaited(save());
    });
  }

  Future<void> _persist() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final snapshot = FeedbackSavedState(draft: _draft, receipts: _receipts);
    final result =
        _saves.catchError((Object _) {}).then((_) => store.save(snapshot));
    _saves = result;
    return result;
  }

  Future<void> save() async {
    if (loading || _loadFailed) return;
    try {
      await _persist();
    } catch (_) {
      _error = const FeedbackFailure('storage');
      _notify();
    }
  }

  Future<FeedbackReceipt?> submit() async {
    if (_disposed || loading || busy) return null;
    if (_loadFailed) {
      _error = const FeedbackFailure('storage');
      _notify();
      return null;
    }
    if (!configured) {
      _error = const FeedbackFailure('unconfigured');
      _notify();
      return null;
    }
    if (!_draft.isValid) {
      _error = const FeedbackFailure('validation');
      _notify();
      return null;
    }
    _busy = true;
    _activeOperation = Completer<void>();
    _error = null;
    final wasAttempted = _draft.attempted;
    _draft = _draft.copyWith(attempted: true);
    _notify();
    try {
      // Save the immutable outbound snapshot BEFORE contacting the service.
      try {
        await _persist();
      } catch (_) {
        _draft = _draft.copyWith(attempted: wasAttempted);
        throw const FeedbackFailure('storage');
      }
      final receipt = await client.submit(_draft);
      _receipts = [
        receipt,
        ..._receipts
            .where((entry) => entry.submissionId != receipt.submissionId)
      ].take(20).toList();
      _draft = FeedbackDraft.empty();
      try {
        await _persist();
      } catch (_) {
        // GitHub creation was confirmed. Report success even if local receipt
        // storage failed; the older persisted nonce still permits safe replay.
        _error = const FeedbackFailure('storage');
      }
      return receipt;
    } on FeedbackFailure catch (failure) {
      _error = failure;
      if (!wasAttempted &&
          ['validation', 'too_large', 'rate_limited', 'unconfigured']
              .contains(failure.code)) {
        _draft = _draft.copyWith(attempted: false);
        try {
          await _persist();
        } catch (_) {}
      }
      return null;
    } catch (_) {
      _error = const FeedbackFailure('network');
      return null;
    } finally {
      _busy = false;
      _activeOperation?.complete();
      _activeOperation = null;
      _notify();
    }
  }

  /// UI must confirm discarding an attempted report: it may already be public.
  Future<void> discardDraft() async {
    if (_disposed || loading || busy) return;
    _loadFailed = false;
    _draft = FeedbackDraft.empty();
    _error = null;
    await save();
    _notify();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // The owning flow awaits waitUntilIdle() and save() before disposal. Do not
    // start an unawaited retry here that could overwrite its successor's draft.
    _disposed = true;
    super.dispose();
  }
}
