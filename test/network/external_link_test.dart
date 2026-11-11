import 'package:clipious/l10n/generated/app_localizations.dart';
import 'package:clipious/utils/views/components/external_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Launcher extends UrlLauncherPlatform {
  final calls = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls.add(url);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const torChannel = MethodChannel('videre/tor_browser');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final torCalls = <MethodCall>[];
  late UrlLauncherPlatform originalLauncher;
  late _Launcher launcher;

  setUp(() {
    originalLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher = _Launcher();
    torCalls.clear();
    messenger.setMockMethodCallHandler(torChannel, (call) async {
      torCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
    messenger.setMockMethodCallHandler(torChannel, null);
  });

  for (final address in [
    'https://music.youtube.com/youtubei/v1/search',
    'https://www.youtube.com/redirect?q=https://instance.example',
    'https://www.youtubeeducation.com/embed/video123456',
    'https://www.youtubekids.com/watch?v=video123456',
    'https://yt.be/activate',
    'https://about.youtube/',
    'https://www.googleapis.com/batch',
    'vnd.youtube:video123456',
    'youtube://watch?v=video123456',
    'intent://watch?v=video123456#Intent;scheme=https;package=com.google.android.youtube;end',
    'javascript:location="https://youtube.com"',
    'https://user:private@instance.example/watch',
  ]) {
    testWidgets('unsupported external destination never launches: $address',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: (context) {
          return TextButton(
              onPressed: () => openExternalLink(context, Uri.parse(address)),
              child: const Text('Open link'));
        })),
      ));
      await tester.tap(find.text('Open link'));
      await tester.pumpAndSettle();
      final locals =
          AppLocalizations.of(tester.element(find.byType(AlertDialog)))!;
      expect(find.text(locals.externalLinkBlocked), findsOneWidget);
      expect(launcher.calls, isEmpty);
      expect(torCalls, isEmpty);
      expect(find.text('Copy to clipboard'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
