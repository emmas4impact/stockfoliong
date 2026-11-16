import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/push_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native Firebase config registers a device and refresh repairs registration', () async {
    setupFirebaseCoreMocks();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('plugins.flutter.io/firebase_messaging');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var allowed = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'Messaging#requestPermission') {
        return {'authorizationStatus': allowed ? 1 : 0};
      }
      if (call.method == 'Messaging#getToken') return {'token': 'test-device'};
      return null;
    });
    addTearDown(() async {
      await PushNotifications.instance.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    final registrations = <String>[];
    Future<PushRegistrationResult> register() => PushNotifications.instance.ensureRegistered(
      registerToken: (token, {required platform}) async => registrations.add('$platform:$token'),
    );
    final first = await register();
    expect(first.enabled, isTrue, reason: first.message);
    expect((await register()).enabled, isTrue);
    expect(registrations, ['android:test-device', 'android:test-device']);
    allowed = false;
    expect((await register()).enabled, isFalse);
    expect(registrations, hasLength(2));
  });
}
