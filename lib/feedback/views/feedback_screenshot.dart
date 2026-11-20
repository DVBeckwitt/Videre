import 'dart:async';
import 'dart:ui' as ui;

import 'package:clipious/utils/motion.dart';
import 'package:feedback/feedback.dart' as capture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';

/// The editor pads its live preview even when closed. Mount it only for a
/// capture so the whole application can receive touches up to the screen edge.
class VidereFeedbackHost extends StatefulWidget {
  const VidereFeedbackHost({super.key, required this.child});

  final Widget child;

  static Future<Uint8List?> capture(BuildContext context) =>
      context.findAncestorStateOfType<_VidereFeedbackHostState>()!._capture();

  @override
  State<VidereFeedbackHost> createState() => _VidereFeedbackHostState();
}

class _VidereFeedbackHostState extends State<VidereFeedbackHost> {
  // Keep playback, navigation, and the report draft alive while reparenting.
  final _appKey = GlobalKey();
  Completer<void>? _closed;

  Future<Uint8List?> _capture() async {
    if (_closed != null) return null;
    final closed = Completer<void>();
    capture.FeedbackController? editor;
    Uint8List? screenshot;
    void onVisibilityChanged() {
      if (editor?.isVisible == false && !closed.isCompleted) closed.complete();
    }

    setState(() => _closed = closed);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final appContext = _appKey.currentContext;
      if (appContext == null || !appContext.mounted) return null;
      editor = capture.BetterFeedback.of(appContext);
      editor.addListener(onVisibilityChanged);
      editor.show((feedback) async {
        screenshot = await prepareFeedbackScreenshot(feedback.screenshot);
        // A cancelled submit must not ask the editor to close a second time.
        if (closed.isCompleted) throw StateError('Screenshot capture closed');
      });
      await closed.future;
      return screenshot;
    } finally {
      editor?.removeListener(onVisibilityChanged);
      if (mounted) {
        setState(() => _closed = null);
        // Reattach the Navigator before the caller reopens the report form.
        await WidgetsBinding.instance.endOfFrame;
      }
    }
  }

  @override
  void dispose() {
    final closed = _closed;
    if (closed != null && !closed.isCompleted) closed.complete();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = KeyedSubtree(key: _appKey, child: widget.child);
    return _closed == null
        ? app
        : capture.BetterFeedback(
            feedbackBuilder: buildFeedbackScreenshotForm,
            localizationsDelegates: [AppLocalizations.delegate],
            child: app,
          );
  }
}

/// Re-encode captured pixels to discard metadata and bound upload dimensions.
Future<Uint8List> prepareFeedbackScreenshot(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final longest = descriptor.width > descriptor.height
        ? descriptor.width
        : descriptor.height;
    final scale = longest > 1280 ? 1280 / longest : 1.0;
    codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round().clamp(1, 1280).toInt(),
      targetHeight: (descriptor.height * scale).round().clamp(1, 1280).toInt(),
    );
    image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > 2 * 1024 * 1024) {
      throw const FormatException('Screenshot is too large.');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Widget buildFeedbackScreenshotForm(BuildContext context,
        capture.OnSubmit onSubmit, ScrollController? scrollController) =>
    _FeedbackScreenshotForm(
      onSubmit: onSubmit,
      scrollController: scrollController,
    );

class _FeedbackScreenshotForm extends StatefulWidget {
  final capture.OnSubmit onSubmit;
  final ScrollController? scrollController;

  const _FeedbackScreenshotForm(
      {required this.onSubmit, this.scrollController});

  @override
  State<_FeedbackScreenshotForm> createState() =>
      _FeedbackScreenshotFormState();
}

class _FeedbackScreenshotFormState extends State<_FeedbackScreenshotForm> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _attach() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.onSubmit('');
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locals = AppLocalizations.of(context) ??
        lookupAppLocalizations(const Locale('en'));
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: ListView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(20),
        children: [
          Text(locals.feedbackScreenshotHelp),
          const SizedBox(height: 12),
          if (_failed) Text(locals.feedbackCaptureFailed),
          if (_busy)
            const MotionLoadingIndicator(child: LinearProgressIndicator()),
          FilledButton.icon(
            key: const ValueKey('feedback-attach-captured-screenshot'),
            onPressed: _busy ? null : _attach,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(locals.feedbackAttachScreenshot),
          ),
        ],
      ),
    );
  }
}
