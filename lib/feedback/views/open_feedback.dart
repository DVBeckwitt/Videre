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
  final player = context.read<PlayerCubit>();
  final controller = FeedbackController(
    collectDiagnostics: () => collectFeedbackDiagnostics(player: player.state),
  );
  _feedbackFormOpen = true;
  try {
    await controller.initialize();
    while (navigator.mounted) {
      final formRoute = MaterialPageRoute<_FeedbackAction>(
        builder: (formContext) => FeedbackFormScreen(
          controller: controller,
          onCaptureScreenshot: () async {
            Navigator.of(formContext).pop(_FeedbackAction.captureScreenshot);
            return null;
          },
        ),
      );
      final result = await navigator.push(formRoute);
      await controller.save();
      if (result != _FeedbackAction.captureScreenshot || !navigator.mounted) {
        break;
      }
      // Let the form finish closing before showing the screen to annotate.
      await formRoute.completed;
      if (!navigator.mounted) break;
      final pixels = await VidereFeedbackHost.capture(navigator.context);
      if (pixels != null) await controller.setScreenshot(pixels);
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
