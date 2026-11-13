import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/biometric_session.dart';
import 'package:flutter_app/biometric_widgets.dart';
import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryVault implements SessionVault {
  final values = <bool, String>{};
  int protectedReads = 0;
  bool cancel = false, failDelete = false;
  @override
  Future<String?> read({required bool biometric}) async {
    if (biometric) {
      protectedReads++;
      if (cancel) throw PlatformException(code: 'cancelled');
    }
    return values[biometric];
  }

  @override
  Future<void> write(String token, {required bool biometric}) async =>
      values[biometric] = token;
  @override
  Future<void> delete({required bool biometric}) async {
    if (failDelete) throw PlatformException(code: 'unavailable');
    values.remove(biometric);
  }
}

BiometricSession session(
  MemoryVault vault, {
  bool available = true,
  bool supported = true,
}) => BiometricSession(
  'https://api.example.test',
  vault: vault,
  supported: supported,
  canAuthenticate: () async => available,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Android requests exactly one activity-bound operation per unlock',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('stockfolio/biometric_session');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      bool cancelled = true;
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.arguments['scope'], 'tester');
        calls.add(call.method);
        if (call.method == 'read' && cancelled) {
          throw PlatformException(
            code: 'biometric',
            message: 'Authentication cancelled',
          );
        }
        return call.method == 'read' ? 'verified-session' : null;
      });
      final store = BiometricSession(
        'origin',
        vault: DeviceSessionVault('tester'),
      );
      SharedPreferences.setMockInitialValues({store.modeKey: 'biometric_v2'});
      expect(await store.restore(), isNull);
      expect(calls, isEmpty);
      await expectLater(store.unlock(), throwsA(isA<SessionUnlockException>()));
      expect(store.prompting, isFalse);
      cancelled = false;
      expect(await store.unlock(), 'verified-session');
      expect(calls, ['read', 'read']);
    },
  );

  test(
    'native vault requires biometric proof per read and device-bound iOS keys',
    () {
      final vault = DeviceSessionVault('test');
      final android = vault.protected.aOptions.toMap();
      final ios = vault.protected.iOptions.toMap();
      expect(android['enforceBiometrics'], 'true');
      expect(android['requireBiometricsPerOperation'], 'true');
      expect(android['biometricType'], 'strongBiometricOnly');
      expect(ios['accessControlFlags'], contains('biometryCurrentSet'));
      expect(ios['accessibility'], 'passcode');
      expect(
        vault.regular.aOptions.storageNamespace,
        isNot(vault.protected.aOptions.storageNamespace),
      );
    },
  );

  test('legacy mobile token moves out of ordinary preferences', () async {
    SharedPreferences.setMockInitialValues({'access_token': 'legacy-token'});
    final vault = MemoryVault();
    final store = session(vault);
    expect(await store.restore(), 'legacy-token');
    expect(vault.values[false], 'legacy-token');
    expect(
      (await SharedPreferences.getInstance()).getString('access_token'),
      isNull,
    );
  });

  test(
    'enable removes unprotected copy; restore never reads protected token',
    () async {
      final vault = MemoryVault();
      final store = session(vault);
      await store.savePasswordSession('token');
      await store.enable('token');
      expect(vault.values[false], isNull);
      expect(store.enabled, isTrue);
      final reads = vault.protectedReads;
      final restarted = session(vault);
      expect(await restarted.restore(), isNull);
      expect(restarted.enabled, isTrue);
      expect(vault.protectedReads, reads);
      expect(await restarted.unlock(), 'token');
      expect(vault.protectedReads, reads + 1);
      await restarted.disable('token');
      expect(restarted.enabled, isFalse);
      expect(vault.values[true], isNull);
      expect(await session(vault).restore(), 'token');
    },
  );

  test('unsupported hardware and cancelled enrollment never enable', () async {
    final vault = MemoryVault();
    final unavailable = session(vault, available: false);
    await expectLater(
      unavailable.enable('token'),
      throwsA(isA<SessionUnlockException>()),
    );
    final store = session(vault);
    await store.savePasswordSession('token');
    vault.cancel = true;
    await expectLater(store.enable('token'), throwsA(isA<PlatformException>()));
    expect(store.enabled, isFalse);
    expect(store.prompting, isFalse);
    expect(await store.restore(), 'token');
  });

  test(
    'logout remains signed out when key deletion fails, reinstall does not restore',
    () async {
      final vault = MemoryVault();
      final store = session(vault);
      await store.savePasswordSession('token');
      await store.enable('token');
      vault.failDelete = true;
      await store.clear();
      expect(await session(vault).restore(), isNull);
      expect(store.enabled, isFalse);
      SharedPreferences.setMockInitialValues({});
      expect(await session(vault).restore(), isNull);
    },
  );

  test(
    'password login replaces enrollment, API origins are isolated',
    () async {
      final vault = MemoryVault();
      final store = session(vault);
      await store.savePasswordSession('first');
      await store.enable('first');
      await store.savePasswordSession('second');
      expect(await session(vault).restore(), 'second');
      expect(vault.values[true], isNull);
      expect(
        await BiometricSession(
          'https://different.test',
          vault: vault,
          supported: true,
        ).restore(),
        isNull,
      );
    },
  );

  test(
    'expired token is cleared; failed network never unlocks or deletes enrollment',
    () async {
      final vault = MemoryVault();
      final store = session(vault);
      await store.savePasswordSession('token');
      await store.enable('token');
      var status = 503;
      final api = ApiClient(
        'https://api.example.test',
        biometricSession: store,
        client: MockClient((request) async {
          expect(request.url.path, '/me');
          expect(request.headers['Authorization'], 'Bearer token');
          return http.Response('{}', status);
        }),
      );
      await api.restoreToken();
      await expectLater(
        api.unlockBiometricSession(),
        throwsA(isA<SessionUnlockException>()),
      );
      expect(api.hasToken, isFalse);
      expect(store.enabled, isTrue);
      status = 401;
      await expectLater(
        api.unlockBiometricSession(),
        throwsA(isA<SessionUnlockException>()),
      );
      expect(api.hasToken, isFalse);
      expect(store.enabled, isFalse);
      expect(vault.values, isEmpty);
    },
  );

  test('logout wins a race against server verification', () async {
    final vault = MemoryVault();
    final store = session(vault);
    await store.savePasswordSession('token');
    await store.enable('token');
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final api = ApiClient(
      'https://api.example.test',
      biometricSession: store,
      client: MockClient((_) {
        requested.complete();
        return response.future;
      }),
    );
    final unlock = api.unlockBiometricSession();
    await requested.future;
    await api.clearToken();
    final expectation = expectLater(
      unlock,
      throwsA(isA<SessionUnlockException>()),
    );
    response.complete(http.Response('{}', 200));
    await expectation;
    expect(api.hasToken, isFalse);
  });

  test('non-native session persistence remains unchanged', () async {
    final api = ApiClient(
      'https://api.example.test',
      biometricSession: session(MemoryVault(), supported: false),
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'access_token': 'web-token'}), 200),
      ),
    );
    await api.login('user@example.test', 'test-password');
    expect(
      (await SharedPreferences.getInstance()).getString('access_token'),
      'web-token',
    );
    await api.clearToken();
    expect(
      (await SharedPreferences.getInstance()).getString('access_token'),
      isNull,
    );
  });

  testWidgets('lock screen preserves password fallback after cancellation', (
    tester,
  ) async {
    bool password = false;
    await tester.pumpWidget(
      MaterialApp(
        home: BiometricUnlockScreen(
          onUnlock: () async => throw PlatformException(code: 'cancelled'),
          onPassword: () async {
            password = true;
          },
        ),
      ),
    );
    await tester.tap(find.text('Unlock with biometrics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cancelled or unavailable'), findsOneWidget);
    await tester.tap(find.text('Use password instead'));
    await tester.pumpAndSettle();
    expect(password, isTrue);
  });

  testWidgets('enrollment requires explicit consent and success', (
    tester,
  ) async {
    final store = session(MemoryVault());
    await store.savePasswordSession('token');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BiometricSettingsTile(
            session: store,
            onChanged: (enable) =>
                enable ? store.enable('token') : store.disable('token'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(store.enabled, isFalse);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    expect(store.enabled, isTrue);
    expect(find.text('On for this device'), findsOneWidget);
  });

  testWidgets('cold start and backgrounding cover authenticated routes', (
    tester,
  ) async {
    final store = session(MemoryVault());
    await store.savePasswordSession('token');
    await store.enable('token');
    final api = ApiClient(
      'https://api.example.test',
      biometricSession: store,
      client: MockClient((request) async {
        final path = request.url.path;
        final Object body = path == '/me'
            ? {'id': 1, 'email': 'demo@example.test'}
            : path.contains('holdings') ||
                  path.contains('news') ||
                  path.contains('offers')
            ? []
            : {};
        return http.Response(jsonEncode(body), 200);
      }),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(NgxPortfolioApp(api: api));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Stockfolio is locked'), findsOneWidget);
    expect(api.hasToken, isFalse);
    // Native biometric callbacks can complete just before the resumed notification.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.tap(find.text('Unlock with biometrics'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.hasToken, isTrue);
    expect(find.text('Stockfolio is locked'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Stockfolio is locked'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('Stockfolio is locked'), findsOneWidget);
    expect(find.byType(DashboardShell), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.text('Use password instead'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Sign in'), findsOneWidget);
    expect(api.hasToken, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
