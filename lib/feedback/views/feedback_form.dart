import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/generated/app_localizations.dart';
import '../feedback_controller.dart';
import '../models/feedback_report.dart';
import 'feedback_screenshot.dart';

class FeedbackFormScreen extends StatefulWidget {
  final FeedbackController controller;
  final Future<Uint8List?> Function()? onCaptureScreenshot;

  const FeedbackFormScreen({
    super.key,
    required this.controller,
    this.onCaptureScreenshot,
  });

  @override
  State<FeedbackFormScreen> createState() => _FeedbackFormScreenState();
}

class _FeedbackFormScreenState extends State<FeedbackFormScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _scroll = ScrollController();
  String? _draftId;
  bool _preview = false;
  bool _capturing = false;
  bool _captureFailed = false;
  FeedbackReceipt? _sent;

  FeedbackController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_changed);
    _syncText();
    unawaited(_controller.initialize());
  }

  void _syncText() {
    final draft = _controller.draft;
    if (_draftId != draft.submissionId) {
      _draftId = draft.submissionId;
      _title.text = draft.title;
      _description.text = draft.description;
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(_syncText);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_controller.save());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_changed);
    unawaited(_controller.save());
    _title.dispose();
    _description.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _showPreview() {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _preview = true);
    _top();
  }

  void _top() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  Future<void> _send() async {
    final receipt = await _controller.submit();
    if (!mounted) return;
    if (receipt != null) setState(() => _sent = receipt);
    _top();
  }

  Future<void> _capture() async {
    if (_capturing || _controller.locked || _controller.busy) return;
    setState(() {
      _capturing = true;
      _captureFailed = false;
    });
    try {
      final bytes = await widget.onCaptureScreenshot?.call();
      if (bytes != null && mounted) {
        await _controller.setScreenshot(await prepareFeedbackScreenshot(bytes));
      }
    } catch (_) {
      if (mounted) setState(() => _captureFailed = true);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _newReport() async {
    final locals = AppLocalizations.of(context)!;
    if ((_controller.locked || _controller.loadFailed) && _sent == null) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(locals.feedbackDiscardTitle),
          content: Text(locals.feedbackDiscardPending),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(locals.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(locals.feedbackStartNew),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    await _controller.discardDraft();
    if (!mounted) return;
    setState(() {
      _sent = null;
      _preview = false;
      _captureFailed = false;
      _syncText();
    });
    _top();
  }

  String _errorMessage(AppLocalizations locals) =>
      switch (_controller.error?.code) {
        'unconfigured' => locals.feedbackUnavailable,
        'pending' || 'conflict' => locals.feedbackPending,
        'rate_limited' => locals.feedbackRateLimited,
        'unavailable' => locals.feedbackServiceUnavailable,
        'github_failed' => locals.feedbackGithubFailed,
        'validation' => locals.feedbackInvalidReport,
        'too_large' => locals.feedbackAttachmentTooLarge,
        'storage' => _controller.loadFailed
            ? locals.feedbackLoadFailed
            : locals.feedbackSaveFailed,
        'diagnostics' => locals.feedbackDiagnosticsFailed,
        'screenshot' => locals.feedbackCaptureFailed,
        _ => locals.feedbackSendFailed,
      };

  Widget _notice(String text, {bool error = false, IconData? icon}) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Card(
        color: error ? colors.errorContainer : colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                  icon ??
                      (error ? Icons.info_outline : Icons.check_circle_outline),
                  color: error
                      ? colors.onErrorContainer
                      : colors.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text,
                    style: TextStyle(
                        color: error
                            ? colors.onErrorContainer
                            : colors.onSecondaryContainer)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _diagnosticLabel(String key, AppLocalizations locals) => switch (key) {
        'appVersion' => locals.feedbackDiagnosticAppVersion,
        'buildNumber' => locals.feedbackDiagnosticBuild,
        'androidVersion' => locals.feedbackDiagnosticAndroid,
        'deviceModel' => locals.feedbackDiagnosticDevice,
        'playerType' => locals.feedbackDiagnosticPlayer,
        'proxyEnabled' => locals.feedbackDiagnosticProxy,
        'recoveryPhase' => locals.feedbackDiagnosticRecovery,
        'alternativeCount' => locals.feedbackDiagnosticAlternatives,
        'manualSelection' => locals.feedbackDiagnosticManual,
        _ => key,
      };

  Widget _diagnostics(Map<String, Object> values, AppLocalizations locals) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in values.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text(
                      '${_diagnosticLabel(entry.key, locals)}: ${entry.value}'),
                ),
            ],
          ),
        ),
      );

  Widget _screenshot(Uint8List bytes, AppLocalizations locals,
          {required bool removable}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(bytes,
                key: const ValueKey('feedback-screenshot-preview'),
                height: 220,
                fit: BoxFit.contain,
                semanticLabel: locals.feedbackScreenshotPreview,
                errorBuilder: (_, __, ___) => _notice(
                    locals.feedbackScreenshotPreviewFailed,
                    error: true)),
          ),
          if (removable)
            TextButton.icon(
              key: const ValueKey('feedback-remove-screenshot'),
              onPressed: () => _controller.setScreenshot(null),
              icon: const Icon(Icons.delete_outline),
              label: Text(locals.feedbackRemoveScreenshot),
            ),
        ],
      );

  List<Widget> _editor(AppLocalizations locals) {
    final draft = _controller.draft;
    final disabled = _controller.busy || _capturing;
    return [
      Text(locals.feedbackFormHelp),
      const SizedBox(height: 20),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          ChoiceChip(
            key: const ValueKey('feedback-kind-bug'),
            avatar: const Icon(Icons.bug_report_outlined),
            label: Text(locals.feedbackBug),
            selected: draft.kind == FeedbackKind.bug,
            onSelected: disabled
                ? null
                : (_) => _controller.update(kind: FeedbackKind.bug),
          ),
          ChoiceChip(
            key: const ValueKey('feedback-kind-suggestion'),
            avatar: const Icon(Icons.lightbulb_outline),
            label: Text(locals.feedbackSuggestion),
            selected: draft.kind == FeedbackKind.suggestion,
            onSelected: disabled
                ? null
                : (_) => _controller.update(kind: FeedbackKind.suggestion),
          ),
        ],
      ),
      const SizedBox(height: 20),
      TextFormField(
        key: const ValueKey('feedback-title'),
        controller: _title,
        enabled: !disabled,
        maxLength: feedbackTitleLimit,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
            labelText: locals.feedbackTitle,
            border: const OutlineInputBorder()),
        validator: (value) => value == null || value.trim().isEmpty
            ? locals.feedbackTitleRequired
            : value.length > feedbackTitleLimit
                ? locals.feedbackInvalidReport
                : null,
        onChanged: (value) => _controller.update(title: value),
      ),
      const SizedBox(height: 12),
      TextFormField(
        key: const ValueKey('feedback-description'),
        controller: _description,
        enabled: !disabled,
        maxLength: feedbackDescriptionLimit,
        minLines: 5,
        maxLines: 12,
        decoration: InputDecoration(
          labelText: locals.feedbackDescription,
          hintText: draft.kind == FeedbackKind.bug
              ? locals.feedbackBugHint
              : locals.feedbackSuggestionHint,
          border: const OutlineInputBorder(),
        ),
        validator: (value) => value == null || value.trim().isEmpty
            ? locals.feedbackDescriptionRequired
            : value.length > feedbackDescriptionLimit
                ? locals.feedbackInvalidReport
                : null,
        onChanged: (value) => _controller.update(description: value),
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        key: const ValueKey('feedback-diagnostics'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: draft.diagnostics != null,
        onChanged: disabled
            ? null
            : (value) => _controller.setIncludeDiagnostics(value ?? false),
        title: Text(locals.feedbackIncludeDiagnostics),
        subtitle: Text(locals.feedbackDiagnosticsHelp),
      ),
      if (draft.diagnostics != null) _diagnostics(draft.diagnostics!, locals),
      if (_controller.busy) ...[
        const LinearProgressIndicator(),
        Text(locals.feedbackPreparingDiagnostics),
      ],
      const SizedBox(height: 12),
      if (draft.screenshot != null)
        _screenshot(draft.screenshot!, locals, removable: !disabled)
      else
        OutlinedButton.icon(
          key: const ValueKey('feedback-add-screenshot'),
          onPressed:
              disabled || widget.onCaptureScreenshot == null ? null : _capture,
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: Text(locals.feedbackAddScreenshot),
        ),
      if (_capturing) const LinearProgressIndicator(),
      if (_captureFailed) _notice(locals.feedbackCaptureFailed, error: true),
      const SizedBox(height: 8),
      Text(locals.feedbackScreenshotPrivacy,
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 24),
      FilledButton.icon(
        key: const ValueKey('feedback-preview'),
        onPressed: disabled ? null : _showPreview,
        icon: const Icon(Icons.preview_outlined),
        label: Text(locals.feedbackPreview),
      ),
      const SizedBox(height: 12),
      Text(locals.feedbackDraftHelp,
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  List<Widget> _review(AppLocalizations locals) {
    final draft = _controller.draft;
    return [
      Text(locals.feedbackPublicNotice),
      const SizedBox(height: 20),
      Text(
          draft.kind == FeedbackKind.bug
              ? locals.feedbackBug
              : locals.feedbackSuggestion,
          style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      SelectableText(draft.title,
          style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 16),
      SelectableText(draft.description),
      const SizedBox(height: 24),
      Text(locals.feedbackIncludeDiagnostics,
          style: Theme.of(context).textTheme.titleMedium),
      if (draft.diagnostics != null)
        _diagnostics(draft.diagnostics!, locals)
      else
        Text(locals.feedbackNotIncluded),
      const SizedBox(height: 16),
      Text(locals.feedbackScreenshot,
          style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (draft.screenshot != null)
        _screenshot(draft.screenshot!, locals, removable: false)
      else
        Text(locals.feedbackNotIncluded),
      const SizedBox(height: 24),
      if (_controller.busy) ...[
        const LinearProgressIndicator(),
        const SizedBox(height: 12),
        Semantics(liveRegion: true, child: Text(locals.feedbackSending)),
        const SizedBox(height: 12),
      ],
      FilledButton.icon(
        key: ValueKey(_controller.locked ? 'feedback-retry' : 'feedback-send'),
        onPressed: _controller.busy || !_controller.configured ? null : _send,
        icon: Icon(_controller.locked ? Icons.refresh : Icons.send_outlined),
        label: Text(_controller.busy
            ? locals.feedbackSending
            : _controller.locked
                ? locals.feedbackRetrySubmission
                : locals.feedbackSend),
      ),
      const SizedBox(height: 8),
      if (!_controller.locked)
        TextButton(
          key: const ValueKey('feedback-edit'),
          onPressed: _controller.busy
              ? null
              : () {
                  setState(() => _preview = false);
                  _top();
                },
          child: Text(locals.feedbackEdit),
        )
      else
        TextButton(
          key: const ValueKey('feedback-new-report'),
          onPressed: _controller.busy ? null : _newReport,
          child: Text(locals.feedbackStartNew),
        ),
    ];
  }

  List<Widget> _receipt(AppLocalizations locals) => [
        _notice(locals.feedbackSubmitted(_sent!.issueNumber)),
        const SizedBox(height: 12),
        if (_controller.error?.code == 'storage')
          _notice(locals.feedbackReceiptSaveFailed, error: true)
        else
          Text(locals.feedbackSubmittedHelp),
        const SizedBox(height: 20),
        FilledButton(
          key: const ValueKey('feedback-new-report'),
          onPressed: _newReport,
          child: Text(locals.feedbackStartNew),
        ),
      ];

  Widget _history(AppLocalizations locals) => ExpansionTile(
        key: const ValueKey('feedback-my-reports'),
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.receipt_long_outlined),
        title: Text(locals.feedbackMyReports),
        children: [
          if (_controller.receipts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(locals.feedbackNoReports),
            ),
          for (final receipt in _controller.receipts)
            ListTile(
              title: Text('#${receipt.issueNumber} · ${receipt.title}'),
              subtitle: Text(MaterialLocalizations.of(context)
                  .formatMediumDate(receipt.createdAt.toLocal())),
              trailing: const Icon(Icons.open_in_new),
              onTap: () async {
                try {
                  final opened = await launchUrl(receipt.issueUrl,
                      mode: LaunchMode.externalApplication);
                  if (!opened && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(locals.feedbackOpenFailed)));
                  }
                } catch (_) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(locals.feedbackOpenFailed)));
                  }
                }
              },
            ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context)!;
    final reviewing = _preview || _controller.locked;
    return PopScope(
      canPop: !_controller.busy,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
        },
        child: Scaffold(
          appBar: AppBar(
              title: Text(reviewing && _sent == null
                  ? locals.feedbackPreview
                  : locals.feedbackFormTitle)),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _controller.loading
                    ? const Center(child: CircularProgressIndicator())
                    : Form(
                        key: _formKey,
                        child: ListView(
                          key: const ValueKey('feedback-form-scroll'),
                          controller: _scroll,
                          padding: const EdgeInsets.all(24),
                          children: [
                            if (!_controller.configured && _sent == null) ...[
                              _notice(locals.feedbackUnavailable, error: true),
                              const SizedBox(height: 16),
                            ],
                            if (_controller.error != null && _sent == null) ...[
                              _notice(_errorMessage(locals), error: true),
                              const SizedBox(height: 16),
                            ],
                            if (_sent != null)
                              ..._receipt(locals)
                            else if (_controller.loadFailed)
                              FilledButton(
                                key: const ValueKey('feedback-new-report'),
                                onPressed: _newReport,
                                child: Text(locals.feedbackStartNew),
                              )
                            else if (reviewing)
                              ..._review(locals)
                            else
                              ..._editor(locals),
                            const SizedBox(height: 24),
                            const Divider(),
                            _history(locals),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
