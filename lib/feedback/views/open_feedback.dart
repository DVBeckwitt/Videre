import 'dart:async';

import 'package:feedback/feedback.dart' as capture;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../player/states/player.dart';
import '../feedback_controller.dart';
import '../services/feedback_diagnostics.dart';
import 'feedback_form.dart';
import 'feedback_screenshot.dart';

enum _FeedbackAction { captureScreenshot }

bool _feedbackFormOpen = false;

/// The form and screenshot editor share one private draft. Capturing or
/// cancelling a screenshot never sends a report or changes diagnostic consent.
Future<void> openFeedbackForm(BuildContext context) async {
  if (_feedbackFormOpen) return;
  final navigator = Navigator.of(context);
  final screenshotController = capture.BetterFeedback.of(context);
  final player = context.read<PlayerCubit>();
  final controller = FeedbackController(
    collectDiagnostics: () => collectFeedbackDiagnostics(player: player.state),
  );
  _feedbackFormOpen = true;
  try {
    await controller.initialize();
    while (navigator.mounted) {
      final result = await navigator.push<_FeedbackAction>(MaterialPageRoute(
        builder: (formContext) => FeedbackFormScreen(
          controller: controller,
          onCaptureScreenshot: () async {
            Navigator.of(formContext).pop(_FeedbackAction.captureScreenshot);
            return null;
          },
        ),
      ));
      await controller.save();
      if (result != _FeedbackAction.captureScreenshot || !navigator.mounted) {
        break;
      }
      final finished = Completer<void>();
      var captureActive = true;
      void onVisibilityChanged() {
        if (!screenshotController.isVisible && !finished.isCompleted) {
          captureActive = false;
          finished.complete();
        }
      }

      screenshotController.addListener(onVisibilityChanged);
      try {
        // Wait until the route transition has removed the report form before
        // exposing the underlying app to the opt-in screenshot editor.
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!navigator.mounted) break;
        screenshotController.show((feedback) async {
          if (!captureActive) return;
          final pixels = await prepareFeedbackScreenshot(feedback.screenshot);
          if (captureActive) await controller.setScreenshot(pixels);
        });
        await finished.future;
      } finally {
        screenshotController.removeListener(onVisibilityChanged);
      }
    }
  } finally {
    try {
      await controller.waitUntilIdle();
      await controller.save();
    } finally {
      controller.dispose();
      _feedbackFormOpen = false;
    }
  }
}
