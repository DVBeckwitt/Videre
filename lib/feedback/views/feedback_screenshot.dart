import 'dart:ui' as ui;

import 'package:feedback/feedback.dart' as capture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';

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
          if (_busy) const LinearProgressIndicator(),
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
