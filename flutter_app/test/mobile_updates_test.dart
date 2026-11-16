import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/mobile_updates.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

final installed = PackageInfo(
  appName: 'Stockfolio',
  packageName: 'com.stockfoliong.app',
  version: '1.1.4',
  buildNumber: '20',
);

AppUpdateInfo playInfo(int version, {bool available = true}) => AppUpdateInfo(
  updateAvailability: available
      ? UpdateAvailability.updateAvailable
      : UpdateAvailability.updateNotAvailable,
  immediateUpdateAllowed: false,
  immediateAllowedPreconditions: null,
  flexibleUpdateAllowed: false,
  flexibleAllowedPreconditions: null,
  availableVersionCode: version,
  installStatus: InstallStatus.unknown,
  packageName: installed.packageName,
  clientVersionStalenessDays: null,
  updatePriority: 0,
);

class FakeUpdates extends MobileUpdates {
  int checks = 0;
  int opens = 0;
  String? ignored;
  bool canOpen = true;
  Completer<MobileUpdate?>? pending;
  final offer = MobileUpdate(
    'android:21',
    Uri.parse(
      'https://play.google.com/store/apps/details?id=com.stockfoliong.app',
    ),
  );
  @override
  Future<MobileUpdate?> check() async {
    checks++;
    return pending == null ? offer : pending!.future;
  }

  @override
  Future<void> ignore(MobileUpdate update) async {
    ignored = update.id;
  }

  @override
  Future<bool> openStore(MobileUpdate update) async {
    opens++;
    return canOpen;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('numeric versions, not lexicographic comparison; never downgrade', () {
    expect(MobileUpdates.newerVersion('1.10.0', '1.9.9'), true);
    expect(MobileUpdates.newerVersion('2.0', '1.99.99'), true);
    expect(MobileUpdates.newerVersion('1.1.4', '1.1.4'), false);
    expect(MobileUpdates.newerVersion('1.1.3', '1.1.4'), false);
    expect(MobileUpdates.newerVersion('1.0.0', '1.0'), false);
    expect(MobileUpdates.newerVersion('unknown', '1.0'), false);
    expect(MobileUpdates.newerVersion('1.5.0', '1.4.0-staging'), false);
  });

  test(
    'Play eligibility, higher build, ignored release and cooldown',
    () async {
      var now = DateTime.utc(2026, 11, 16);
      var calls = 0;
      var version = 21;
      final service = MobileUpdates(
        platform: TargetPlatform.android,
        packageInfo: () async => installed,
        now: () => now,
        playCheck: () async {
          calls++;
          return playInfo(version);
        },
      );
      final offer = (await service.check())!;
      expect(offer.id, 'android:com.stockfoliong.app:21');
      expect(offer.storeUrl.host, 'play.google.com');
      expect(await service.check(), isNull);
      expect(calls, 1);
      await service.ignore(offer);
      now = now.add(const Duration(hours: 6));
      expect(await service.check(), isNull);
      version = 22;
      now = now.add(const Duration(hours: 6));
      expect((await service.check())!.id, endsWith(':22'));
      final restarted = MobileUpdates(
        platform: TargetPlatform.android,
        packageInfo: () async => installed,
        playCheck: () async => playInfo(21),
      );
      expect(await restarted.check(), isNull);
      final notReleased = MobileUpdates(
        platform: TargetPlatform.android,
        packageInfo: () async => installed,
        playCheck: () async => playInfo(100, available: false),
      );
      expect(await notReleased.check(), isNull);
      final same = MobileUpdates(
        platform: TargetPlatform.android,
        packageInfo: () async => installed,
        playCheck: () async => playInfo(20),
      );
      expect(await same.check(), isNull);
    },
  );

  test('store failures and unsupported platforms are silent', () async {
    final service = MobileUpdates(
      platform: TargetPlatform.android,
      packageInfo: () async => installed,
      playCheck: () async => throw Exception('Not installed from Play'),
    );
    expect(await service.check(), isNull);
    final desktop = MobileUpdates(
      platform: TargetPlatform.linux,
      packageInfo: () => throw StateError('Must not call platform plugins'),
    );
    expect(await desktop.check(), isNull);
  });

  test(
    'Apple lookup checks bundle, version and store host; unlisted build stays usable',
    () async {
      var result = <String, dynamic>{
        'bundleId': installed.packageName,
        'version': '1.2.0',
        'trackViewUrl': 'https://apps.apple.com/ng/app/stockfolio/id123456',
      };
      Future<MobileUpdate?> check() => MobileUpdates(
        platform: TargetPlatform.iOS,
        packageInfo: () async => installed,
        client: MockClient((request) async {
          expect(request.url.host, 'itunes.apple.com');
          expect(
            request.url.queryParameters['bundleId'],
            installed.packageName,
          );
          return http.Response(
            jsonEncode({
              'results': [result],
            }),
            200,
          );
        }),
      ).check();
      expect((await check())!.version, '1.2.0');
      result['version'] = '1.1.4';
      expect(await check(), isNull);
      result['version'] = '1.2.0';
      result['bundleId'] = 'another.app';
      expect(await check(), isNull);
      result['bundleId'] = installed.packageName;
      result['trackViewUrl'] = 'https://untrusted.example/download';
      expect(await check(), isNull);
      result = {};
      expect(await check(), isNull);
    },
  );

  for (final accept in [false, true]) {
    testWidgets('optional prompt: ${accept ? "update" : "ignore"}', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final service = FakeUpdates();
      final navigator = GlobalKey<NavigatorState>();
      Widget app(bool enabled) => MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => MobileUpdatePrompt(
          navigatorKey: navigator,
          enabled: enabled,
          updates: service,
          child: child!,
        ),
        home: const Scaffold(body: Text('Portfolio')),
      );
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(service.checks, 0);
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(find.text('Update available'), findsOneWidget);
      await tester.tap(find.text(accept ? 'Update now' : 'Ignore'));
      await tester.pumpAndSettle();
      expect(service.opens, accept ? 1 : 0);
      expect(service.ignored, accept ? isNull : service.offer.id);
      expect(find.text('Portfolio'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'defers an in-flight offer while locked and recovers from store failure',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final service = FakeUpdates()..canOpen = false;
      service.pending = Completer<MobileUpdate?>();
      final navigator = GlobalKey<NavigatorState>();
      Widget app(bool enabled) => MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => MobileUpdatePrompt(
          navigatorKey: navigator,
          enabled: enabled,
          updates: service,
          child: child!,
        ),
        home: const Scaffold(body: Text('Portfolio')),
      );
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(false));
      service.pending!.complete(service.offer);
      await tester.pumpAndSettle();
      expect(find.text('Update available'), findsNothing);
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(service.checks, 1);
      expect(find.text('Update available'), findsOneWidget);
      await tester.tap(find.text('Update now'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not open the store. Please update Stockfolio from your app store.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
