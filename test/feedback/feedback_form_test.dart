import 'dart:async';
import 'dart:convert';

import 'package:clipious/feedback/feedback_controller.dart';
import 'package:clipious/feedback/models/feedback_report.dart';
import 'package:clipious/feedback/services/feedback_store.dart';
import 'package:clipious/feedback/services/feedback_submission_client.dart';
import 'package:clipious/feedback/views/feedback_form.dart';
import 'package:clipious/feedback/views/feedback_screenshot.dart';
import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:feedback/feedback.dart' as capture;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _UnavailableIssueLauncher extends UrlLauncherPlatform {
  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    throw PlatformException(
        code: 'unavailable', message: 'private-platform-detail');
  }
}

class _MemoryFeedbackStore implements FeedbackStore {
  FeedbackSavedState state = FeedbackSavedState();

  @override
  Future<FeedbackSavedState> load() async => state;

  @override
  Future<void> save(FeedbackSavedState value) async {
    state = value;
  }
}

class _CorruptFeedbackStore extends _MemoryFeedbackStore {
  int saves = 0;

  @override
  Future<FeedbackSavedState> load() async {
    throw const FormatException('Invalid saved report');
  }

  @override
  Future<void> save(FeedbackSavedState value) async {
    saves++;
    await super.save(value);
  }
}

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

http.Response _created([int issue = 123]) => http.Response(
      jsonEncode({
        'status': 'created',
        'issueNumber': issue,
        'issueUrl': 'https://github.com/DVBeckwitt/Videre/issues/$issue',
      }),
      201,
      headers: {'content-type': 'application/json'},
    );

void main() {
  Finder keyed(String suffix) => find.byKey(ValueKey('feedback-$suffix'));

  Future<void> reveal(WidgetTester tester, Finder target,
      {double delta = 180}) async {
    if (target.evaluate().isNotEmpty) {
      await tester.ensureVisible(target);
    } else {
      await tester.scrollUntilVisible(target, delta,
          scrollable: find.byType(Scrollable).first, maxScrolls: 35);
    }
    await tester.pumpAndSettle();
    expect(target.hitTestable(), findsOneWidget);
  }

  Future<void> tap(WidgetTester tester, String key,
      {bool settle = true, double delta = 180}) async {
    await reveal(tester, keyed(key), delta: delta);
    await tester.tap(keyed(key));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  Future<FeedbackController> pumpForm(
    WidgetTester tester, {
    Future<http.Response> Function(http.Request)? send,
    Future<Map<String, Object>> Function()? collectDiagnostics,
    Future<Uint8List?> Function()? capture,
    FeedbackStore? store,
    bool configured = true,
    double textScale = 1,
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final controller = FeedbackController(
      client: FeedbackSubmissionClient(
        endpoint: Uri.parse(configured
            ? 'https://feedback.example'
            : 'http://not-permitted.example'),
        client: MockClient(send ?? (_) async => _created()),
        timeout: timeout,
      ),
      store: store ?? _MemoryFeedbackStore(),
      collectDiagnostics:
          collectDiagnostics ?? () async => {'appVersion': '1.2.3'},
    );
    await controller.initialize();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: FeedbackFormScreen(
        controller: controller,
        onCaptureScreenshot: capture,
      ),
    ));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
    return controller;
  }

  Future<void> fill(WidgetTester tester,
      {String title = 'Playback stops',
      String description = 'Open a video and change its backend.'}) async {
    await reveal(tester, keyed('title'), delta: -180);
    await tester.enterText(keyed('title'), title);
    await reveal(tester, keyed('description'));
    await tester.enterText(keyed('description'), description);
    FocusManager.instance.primaryFocus?.unfocus();
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
  }

  testWidgets('bug form validates and previews before sending either opt-in',
      (tester) async {
    final requests = <Map<String, dynamic>>[];
    var collections = 0;
    var captures = 0;
    final controller = await pumpForm(tester, send: (request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return _created();
    }, collectDiagnostics: () async {
      collections++;
      return {'appVersion': '1.2.3'};
    }, capture: () async {
      captures++;
      return _png;
    });

    expect(controller.draft.kind, FeedbackKind.bug);
    expect(controller.draft.diagnostics, isNull);
    expect(controller.draft.screenshot, isNull);
    await tap(tester, 'preview');
    expect(requests, isEmpty);
    expect(keyed('send'), findsNothing);
    await fill(tester);
    await tap(tester, 'preview');
    expect(requests, isEmpty);
    expect(find.text('Playback stops'), findsOneWidget);
    await tap(tester, 'send');

    expect(requests, hasLength(1));
    expect(requests.single['kind'], 'bug');
    expect(requests.single['title'], 'Playback stops');
    expect(requests.single.containsKey('diagnostics'), isFalse);
    expect(requests.single.containsKey('screenshot'), isFalse);
    expect(collections, 0);
    expect(captures, 0);
    expect(controller.receipts.single.issueNumber, 123);
    expect(find.textContaining('#123'), findsWidgets);
  });

  testWidgets('suggestion selection is preserved in the submitted report',
      (tester) async {
    Map<String, dynamic>? submitted;
    await pumpForm(tester, send: (request) async {
      submitted = jsonDecode(request.body) as Map<String, dynamic>;
      return _created(124);
    });
    await tap(tester, 'kind-suggestion');
    await fill(tester,
        title: 'Add a queue shortcut',
        description:
            'A shortcut beside the player would make the queue easier to find.');
    await tap(tester, 'preview');
    expect(submitted, isNull);
    await tap(tester, 'send');
    expect(submitted!['kind'], 'suggestion');
    expect(submitted!['description'], contains('queue easier to find'));
  });

  testWidgets(
      'optional diagnostics and screenshot can be previewed and removed',
      (tester) async {
    Map<String, dynamic>? submitted;
    var collections = 0;
    final controller = await pumpForm(tester,
        send: (request) async {
          submitted = jsonDecode(request.body) as Map<String, dynamic>;
          return _created();
        },
        collectDiagnostics: () async {
          collections++;
          return {'appVersion': '1.2.3', 'proxyEnabled': true};
        },
        capture: () async => _png);
    await fill(tester);
    await tap(tester, 'diagnostics');
    await reveal(tester, keyed('add-screenshot'));
    // Image codecs complete on engine worker threads, outside the widget
    // test's fake clock. Exercise the actual capture button in real async time.
    await tester.runAsync(() async {
      await tester.tap(keyed('add-screenshot'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.draft.screenshot == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(collections, 1);
    expect(controller.draft.diagnostics!['appVersion'], '1.2.3');
    expect(controller.draft.screenshot, isNotNull);
    expect(validFeedbackScreenshot(controller.draft.screenshot!), isTrue);
    await tap(tester, 'preview');
    expect(find.textContaining('1.2.3'), findsWidgets);
    expect(find.byType(Image), findsOneWidget);
    expect(submitted, isNull);
    await tap(tester, 'edit');
    await tap(tester, 'remove-screenshot');
    await tap(tester, 'diagnostics', delta: -180);
    expect(controller.draft.screenshot, isNull);
    expect(controller.draft.diagnostics, isNull);
    await tap(tester, 'preview');
    await tap(tester, 'send');
    expect(submitted!.containsKey('diagnostics'), isFalse);
    expect(submitted!.containsKey('screenshot'), isFalse);
  });

  testWidgets('send is disabled while the report is in flight', (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    await pumpForm(tester, send: (_) {
      requests++;
      return response.future;
    });
    await fill(tester);
    await tap(tester, 'preview');
    await tap(tester, 'send', settle: false);
    expect(requests, 1);
    expect(tester.widget<FilledButton>(keyed('retry')).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<PopScope>(find.byType(PopScope).last).canPop, isFalse);
    response.complete(_created());
    await tester.pumpAndSettle();
    expect(tester.widget<PopScope>(find.byType(PopScope).last).canPop, isTrue);
    expect(requests, 1);
    expect(find.textContaining('#123'), findsWidgets);
  });

  testWidgets('pending report is not called sent and retry keeps its exact ID',
      (tester) async {
    final requests = <Map<String, dynamic>>[];
    final controller = await pumpForm(tester, send: (request) async {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      return requests.length == 1
          ? http.Response('{"status":"pending"}', 202)
          : _created();
    });
    await fill(tester);
    await tap(tester, 'preview');
    await tap(tester, 'send');
    expect(controller.locked, isTrue);
    expect(controller.receipts, isEmpty);
    expect(find.textContaining('#123'), findsNothing);
    expect(controller.draft.title, 'Playback stops');
    await tap(tester, 'retry');
    expect(requests, hasLength(2));
    expect(requests.last, requests.first);
    expect(controller.receipts.single.issueNumber, 123);
    expect(find.textContaining('#123'), findsWidgets);
  });

  testWidgets('submission failure retains the draft and hides raw server text',
      (tester) async {
    final controller = await pumpForm(tester,
        send: (_) async => http.Response(
            '{"error":"unavailable","detail":"SID=private-cookie"}', 503));
    await fill(tester);
    await tap(tester, 'preview');
    await tap(tester, 'send');
    expect(controller.receipts, isEmpty);
    expect(controller.draft.title, 'Playback stops');
    expect(controller.draft.description, contains('change its backend'));
    expect(find.textContaining('private-cookie'), findsNothing);
    expect(controller.locked, isTrue);
    expect(tester.widget<FilledButton>(keyed('retry')).onPressed, isNotNull);
    expect(
        find.textContaining('feedback service is unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['offline', 'timeout', 'github', 'invalid_response']) {
    testWidgets('$failure submission shows a safe notice and keeps the report',
        (tester) async {
      final waiting = Completer<http.Response>();
      final store = _MemoryFeedbackStore();
      var requests = 0;
      final controller = await pumpForm(tester,
          store: store,
          timeout: const Duration(milliseconds: 20), send: (_) async {
        requests++;
        switch (failure) {
          case 'offline':
            throw StateError('private-network-detail');
          case 'timeout':
            return waiting.future;
          case 'github':
            return http.Response('private-github-detail', 502);
          default:
            return http.Response('private-invalid-response', 201);
        }
      });
      await fill(tester);
      final submissionId = controller.draft.submissionId;
      await tap(tester, 'preview');
      await tap(tester, 'send');
      expect(requests, 1);
      expect(controller.busy, isFalse);
      expect(controller.receipts, isEmpty);
      expect(controller.draft.submissionId, submissionId);
      expect(controller.draft.title, 'Playback stops');
      expect(store.state.draft?.submissionId, submissionId);
      expect(
          find.textContaining(failure == 'github'
              ? 'GitHub could not accept'
              : 'Could not confirm submission'),
          findsOneWidget);
      expect(find.textContaining('private-'), findsNothing);
      expect(tester.widget<FilledButton>(keyed('retry')).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      if (failure == 'timeout') waiting.complete(_created());
    });
  }

  testWidgets(
      'unreadable screenshot shows a recoverable notice instead of an image error',
      (tester) async {
    final store = _MemoryFeedbackStore()
      ..state = FeedbackSavedState(
          draft: FeedbackDraft.empty().copyWith(
              title: 'Saved report',
              description: 'Keep these details.',
              screenshot: Uint8List.fromList(_png.take(33).toList())));
    final controller = await pumpForm(tester, store: store);
    await reveal(tester, keyed('screenshot-preview'));
    final failureNotice =
        find.textContaining('Could not display this screenshot');
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (
        failureNotice.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    expect(failureNotice, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(controller.draft.title, 'Saved report');
    await tap(tester, 'remove-screenshot');
    expect(controller.draft.screenshot, isNull);
    expect(controller.draft.description, 'Keep these details.');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'an unavailable issue launcher shows a notice without losing the receipt',
      (tester) async {
    final originalLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = _UnavailableIssueLauncher();
    addTearDown(() => UrlLauncherPlatform.instance = originalLauncher);
    final controller = await pumpForm(tester);
    await fill(tester);
    await tap(tester, 'preview');
    await tap(tester, 'send');
    await tap(tester, 'my-reports');
    final issue = find.text('#123 · Playback stops');
    await reveal(tester, issue);
    await tester.tap(issue);
    await tester.pumpAndSettle();
    expect(find.text('Could not open the issue. Please try again.'),
        findsOneWidget);
    expect(find.textContaining('private-platform-detail'), findsNothing);
    expect(controller.receipts.single.issueNumber, 123);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'unreadable saved report requires confirmation before replacement',
      (tester) async {
    final store = _CorruptFeedbackStore();
    final controller = await pumpForm(tester, store: store);
    expect(controller.loadFailed, isTrue);
    expect(find.byType(TextFormField), findsNothing);
    expect(store.saves, 0);

    await tap(tester, 'new-report');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(store.saves, 0);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Cancel')));
    await tester.pumpAndSettle();
    expect(controller.loadFailed, isTrue);
    expect(find.byType(TextFormField), findsNothing);
    expect(store.saves, 0);

    await tap(tester, 'new-report');
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(controller.loadFailed, isFalse);
    await reveal(tester, keyed('title'));
    expect(keyed('title'), findsOneWidget);
    expect(store.saves, greaterThan(0));
    expect(controller.draft.title, isEmpty);
  });
  testWidgets('unconfigured service does not send and preserves a local draft',
      (tester) async {
    var requests = 0;
    final store = _MemoryFeedbackStore();
    final controller = await pumpForm(tester, configured: false, store: store,
        send: (_) async {
      requests++;
      return _created();
    });
    await fill(tester);
    await tap(tester, 'preview');
    expect(tester.widget<FilledButton>(keyed('send')).onPressed, isNull);
    await controller.save();
    expect(requests, 0);
    expect(store.state.draft!.title, 'Playback stops');
    expect(controller.receipts, isEmpty);
    expect(
        find.textContaining('not available in this build yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'small screen with large text can reach preview and return to edit',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpForm(tester, textScale: 2);
    await fill(tester);
    await tap(tester, 'preview');
    expect(tester.takeException(), isNull);
    await tap(tester, 'edit');
    await reveal(tester, keyed('title'), delta: -180);
    expect(tester.widget<TextFormField>(keyed('title')).controller!.text,
        'Playback stops');
    expect(tester.takeException(), isNull);
  });

  testWidgets('remote Select activates the focused preview action',
      (tester) async {
    await pumpForm(tester);
    await fill(tester);
    await reveal(tester, keyed('preview'));
    final label = find
        .descendant(of: keyed('preview'), matching: find.byType(Text))
        .first;
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(keyed('send'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('en'), const Locale('af')]) {
    testWidgets(
        'screenshot editor supports ${locale.languageCode} and cancel without submitting',
        (tester) async {
      late capture.FeedbackController screenshotController;
      var captures = 0;
      await tester.pumpWidget(capture.BetterFeedback(
        localeOverride: locale,
        feedbackBuilder: buildFeedbackScreenshotForm,
        localizationsDelegates: [AppLocalizations.delegate],
        child: MaterialApp(
          home: Builder(builder: (context) {
            screenshotController = capture.BetterFeedback.of(context);
            return const Scaffold(body: Text('Screen to annotate'));
          }),
        ),
      ));
      screenshotController.show((_) async {
        captures++;
      });
      await tester.pumpAndSettle();
      expect(keyed('attach-captured-screenshot'), findsOneWidget);
      expect(captures, 0);
      expect(tester.takeException(), isNull);
      screenshotController.hide();
      await tester.pumpAndSettle();
      expect(captures, 0);
      expect(keyed('attach-captured-screenshot'), findsNothing);
    });
  }
}
