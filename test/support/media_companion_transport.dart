import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void mockMediaCompanionTransport({
  Future<void> Function(MethodCall call)? onSetOrigins,
}) {
  const channel = MethodChannel('videre/proxy');
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    if (call.method != 'setMediaCompanionOrigins') {
      throw MissingPluginException();
    }
    await onSetOrigins?.call(call);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}
