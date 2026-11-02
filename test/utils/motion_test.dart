import 'package:clipious/utils.dart';
import 'package:clipious/utils/motion.dart';
import 'package:clipious/utils/motion_binding.dart';
import 'package:clipious/utils/views/components/motion_animation.dart';
import 'package:clipious/utils/views/components/navigation_switcher.dart';
import 'package:clipious/utils/views/components/placeholders.dart';
import 'package:clipious/utils/views/tv/components/tv_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _MotionTestBinding extends AutomatedTestWidgetsFlutterBinding
    with InterfaceMotionBinding {}

void main() {
  final binding = _MotionTestBinding();
  late ValueNotifier<MotionPreference> preference;
  late ValueNotifier<bool> systemOff;

  setUp(() {
    preference = ValueNotifier(MotionPreference.system);
    systemOff = ValueNotifier(false);
  });
  tearDown(() {
    binding.reduceInterfaceMotion = false;
    preference.dispose();
    systemOff.dispose();
  });

  Widget app(Widget home) => MaterialApp(
      builder: (context, child) => ValueListenableBuilder(
          valueListenable: systemOff,
          builder: (context, off, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: off),
              child: ValueListenableBuilder(
                  valueListenable: preference,
                  builder: (context, value, _) =>
                      MotionScope(preference: value, child: child!)))),
      home: home);

  for (final mode in MotionPreference.values) {
    testWidgets('${mode.name}: fade finishes and preserves child state',
        (tester) async {
      preference.value = mode;
      await tester.pumpWidget(app(
          Scaffold(body: MotionAnimation.fadeIn(child: const TextField()))));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final fade = tester.widget<FadeTransition>(find
          .ancestor(
              of: find.byType(TextField), matching: find.byType(FadeTransition))
          .first);
      switch (mode) {
        case MotionPreference.system:
          expect(fade.opacity.value, closeTo(0.2, 0.01));
        case MotionPreference.reduced:
          expect(fade.opacity.value, closeTo(0.5, 0.01));
        case MotionPreference.off:
          expect(fade.opacity.value, 1);
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(fade.opacity.value, 1);
      await tester.enterText(find.byType(TextField), 'Keep this input');
      preference.value = MotionPreference.off;
      await tester.pumpAndSettle();
      expect(find.text('Keep this input'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'built-in controllers honor the preference without freezing callbacks',
      (tester) async {
    final controller = AnimationController(
        vsync: tester, duration: const Duration(milliseconds: 200));
    addTearDown(controller.dispose);
    await tester.pumpWidget(app(const SizedBox()));
    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.isCompleted, isFalse);
    controller.reset();
    preference.value = MotionPreference.off;
    await tester.pump();
    var completed = false;
    controller.forward().then((_) => completed = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.isCompleted, isTrue);
    expect(completed, isTrue);
    preference.value = MotionPreference.system;
    await tester.pump();
    controller.reset();
    controller.forward();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(controller.isCompleted, isFalse);
    controller.stop();
  });

  testWidgets(
      'defaults preserve motion; live OS and preference changes propagate',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(app(Builder(builder: (ctx) {
      context = ctx;
      return const SizedBox();
    })));
    expect(AppMotion.of(context), MotionLevel.full);
    expect(AppMotion.duration(context), const Duration(milliseconds: 250));
    preference.value = MotionPreference.reduced;
    await tester.pump();
    expect(AppMotion.duration(context), Duration.zero);
    expect(AppMotion.fadeDuration(context), const Duration(milliseconds: 100));
    expect(MediaQuery.disableAnimationsOf(context), isTrue);
    systemOff.value = true;
    await tester.pump();
    expect(AppMotion.of(context), MotionLevel.off);
    expect(AppMotion.fadeDuration(context), Duration.zero);
    systemOff.value = false;
    preference.value = MotionPreference.off;
    await tester.pump();
    expect(AppMotion.of(context), MotionLevel.off);
    preference.value = MotionPreference.system;
    await tester.pump();
    expect(AppMotion.of(context), MotionLevel.full);
    expect(MediaQuery.disableAnimationsOf(context), isFalse);
  });

  testWidgets('preference updates preserve active routes and text input',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(app(Navigator(
        key: navigator,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Home'))))));
    final route = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: TextField()));
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this query');
    preference.value = MotionPreference.off;
    await tester.pumpAndSettle();
    expect(find.text('Keep this query'), findsOneWidget);
    expect(route.isCurrent, isTrue);
    expect(route.reverseTransitionDuration, Duration.zero);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    preference.value = MotionPreference.reduced;
    await tester.pump();
    final reducedRoute =
        MaterialPageRoute<void>(builder: (_) => const SizedBox());
    navigator.currentState!.push(reducedRoute);
    await tester.pumpAndSettle();
    expect(reducedRoute.transitionDuration, const Duration(milliseconds: 100));
    preference.value = MotionPreference.system;
    await tester.pump();
    expect(reducedRoute.reverseTransitionDuration,
        const Duration(milliseconds: 300));
  });

  testWidgets('Off sheets open without movement and remain dismissible',
      (tester) async {
    preference.value = MotionPreference.off;
    await tester.pumpWidget(app(Builder(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () => showSafeModalBottomSheet<void>(
                    context: context,
                    builder: (_) =>
                        const SizedBox(height: 100, child: Text('Queue'))),
                child: const Text('Open'))))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final sheetContext = tester.element(find.text('Queue'));
    final route = ModalRoute.of(sheetContext)!;
    expect(route.transitionDuration, Duration.zero);
    Navigator.of(sheetContext).pop();
    await tester.pumpAndSettle();
    expect(find.text('Queue'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('restricted scrolling jumps safely and normal scrolling returns',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    late BuildContext context;
    await tester.pumpWidget(app(Builder(builder: (ctx) {
      context = ctx;
      return ListView(
          controller: controller, children: const [SizedBox(height: 3000)]);
    })));
    for (final value in [MotionPreference.reduced, MotionPreference.off]) {
      preference.value = value;
      await tester.pump();
      await AppMotion.scrollTo(context, controller, 400);
      expect(controller.offset, 400);
      await AppMotion.scrollTo(context, controller, 0);
      expect(controller.offset, 0);
    }
    preference.value = MotionPreference.system;
    await tester.pump();
    final scrolling = AppMotion.scrollTo(context, controller, 400);
    await tester.pumpAndSettle();
    await scrolling;
    expect(controller.offset, 400);
    expect(tester.takeException(), isNull);
  });

  testWidgets('placeholders stop pulsing and can resume after a live change',
      (tester) async {
    await tester
        .pumpWidget(app(const AnimatedPlaceHolder(child: Text('Loading'))));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, isTrue);
    for (final value in [MotionPreference.reduced, MotionPreference.off]) {
      preference.value = value;
      await tester.pumpAndSettle();
      expect(find.text('Loading'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
    preference.value = MotionPreference.system;
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets(
      'Off stops only loading animation and keeps real progress updates',
      (tester) async {
    final progress = ValueNotifier<double?>(null);
    addTearDown(progress.dispose);
    await tester.pumpWidget(app(ValueListenableBuilder(
        valueListenable: progress,
        builder: (context, value, _) => Center(
            child: MotionLoadingIndicator(
                child: CircularProgressIndicator(
                    value: value, semanticsLabel: 'Downloading'))))));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    preference.value = MotionPreference.off;
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    progress.value = 0.7;
    await tester.pump();
    expect(
        tester
            .widget<CircularProgressIndicator>(
                find.byType(CircularProgressIndicator))
            .value,
        0.7);
    preference.value = MotionPreference.system;
    progress.value = null;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('Reduced switcher uses a fade without scaling', (tester) async {
    preference.value = MotionPreference.reduced;
    await tester
        .pumpWidget(app(const NavigationSwitcher(child: Text('History'))));
    expect(find.byType(ScaleTransition), findsNothing);
    expect(find.text('History'), findsOneWidget);
    expect(
        tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher)).duration,
        const Duration(milliseconds: 100));
  });

  testWidgets('Off TV buttons retain focus highlight and D-pad activation',
      (tester) async {
    preference.value = MotionPreference.off;
    var activated = 0;
    await tester.pumpWidget(app(Scaffold(
        body: TvButton(
            autofocus: true,
            focusedColor: Colors.red,
            onPressed: (_) => activated++,
            child: const Text('Play')))));
    await tester.pumpAndSettle();
    final button = tester.widget<AnimatedContainer>(find.descendant(
        of: find.byType(TvButton), matching: find.byType(AnimatedContainer)));
    expect(button.duration, Duration.zero);
    expect((button.decoration! as BoxDecoration).color, Colors.red);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(activated, 1);
    expect(tester.takeException(), isNull);
  });
}
