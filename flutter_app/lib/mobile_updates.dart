import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class MobileUpdate {
  const MobileUpdate(this.id, this.storeUrl, {this.version});
  final String id;
  final Uri storeUrl;
  final String? version;
}

class MobileUpdates {
  MobileUpdates({
    this.platform,
    this.packageInfo = PackageInfo.fromPlatform,
    this.playCheck = InAppUpdate.checkForUpdate,
    this.now = DateTime.now,
    http.Client? client,
  }) : _client = client;

  final TargetPlatform? platform;
  final Future<PackageInfo> Function() packageInfo;
  final Future<AppUpdateInfo> Function() playCheck;
  final DateTime Function() now;
  final http.Client? _client;
  DateTime? _checkedAt;
  bool _checking = false;
  String? _presented;
  static const _ignoredKey = 'ignored_mobile_store_release';

  Future<MobileUpdate?> check() async {
    final target = platform ?? defaultTargetPlatform;
    if (kIsWeb ||
        !{TargetPlatform.android, TargetPlatform.iOS}.contains(target) ||
        _checking ||
        (_checkedAt != null &&
            now().difference(_checkedAt!) < const Duration(hours: 6))) {
      return null;
    }
    _checking = true;
    _checkedAt = now();
    try {
      final installed = await packageInfo();
      MobileUpdate? update;
      if (target == TargetPlatform.android) {
        final info = await playCheck().timeout(const Duration(seconds: 15));
        final current = int.tryParse(installed.buildNumber);
        final available = info.availableVersionCode;
        if (info.updateAvailability == UpdateAvailability.updateAvailable &&
            info.packageName == installed.packageName &&
            current != null &&
            available != null &&
            available > current) {
          update = MobileUpdate(
            'android:${installed.packageName}:$available',
            Uri.https('play.google.com', '/store/apps/details', {
              'id': installed.packageName,
            }),
          );
        }
      } else {
        update = await _appleUpdate(installed);
      }
      final prefs = await SharedPreferences.getInstance();
      if (update == null ||
          prefs.getString(_ignoredKey) == update.id ||
          _presented == update.id) {
        return null;
      }
      return update;
    } catch (_) {
      // Store access is optional: offline, sideloaded and unpublished builds still work.
      return null;
    } finally {
      _checking = false;
    }
  }

  Future<MobileUpdate?> _appleUpdate(PackageInfo installed) async {
    final client = _client ?? http.Client();
    try {
      const configuredCountry = String.fromEnvironment('APP_STORE_COUNTRY');
      final country = configuredCountry.isNotEmpty
          ? configuredCountry
          : (WidgetsBinding.instance.platformDispatcher.locale.countryCode ??
                'NG');
      final response = await client
          .get(
            Uri.https('itunes.apple.com', '/lookup', {
              'bundleId': installed.packageName,
              'entity': 'software',
              'country': country,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final payload = jsonDecode(response.body);
      if (payload is! Map || payload['results'] is! List) return null;
      for (final result in payload['results'] as List) {
        if (result is! Map ||
            result['bundleId'] != installed.packageName ||
            result['version'] is! String ||
            result['trackViewUrl'] is! String) {
          continue;
        }
        final version = result['version'] as String;
        final url = Uri.tryParse(result['trackViewUrl'] as String);
        if (url != null &&
            url.scheme == 'https' &&
            url.host == 'apps.apple.com' &&
            url.userInfo.isEmpty &&
            newerVersion(version, installed.version)) {
          return MobileUpdate(
            'ios:${installed.packageName}:$version',
            url,
            version: version,
          );
        }
      }
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  static bool newerVersion(String available, String installed) {
    final format = RegExp(r'^\d+(\.\d+){0,2}$');
    if (!format.hasMatch(available) || !format.hasMatch(installed)) {
      return false;
    }
    final a = available.split('.').map(int.parse).toList();
    final b = installed.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final difference = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
      if (difference != 0) return difference > 0;
    }
    return false;
  }

  void presented(MobileUpdate update) => _presented = update.id;

  Future<void> ignore(MobileUpdate update) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ignoredKey, update.id);
  }

  Future<bool> openStore(MobileUpdate update) =>
      launchUrl(update.storeUrl, mode: LaunchMode.externalApplication);
}

/// Lives above routes so returning from the store does not create another prompt.
class MobileUpdatePrompt extends StatefulWidget {
  const MobileUpdatePrompt({
    super.key,
    required this.navigatorKey,
    required this.enabled,
    required this.child,
    this.updates,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final bool enabled;
  final Widget child;
  final MobileUpdates? updates;

  @override
  State<MobileUpdatePrompt> createState() => _MobileUpdatePromptState();
}

class _MobileUpdatePromptState extends State<MobileUpdatePrompt>
    with WidgetsBindingObserver {
  late final updates = widget.updates ?? MobileUpdates();
  bool _busy = false;
  MobileUpdate? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(MobileUpdatePrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (!mounted ||
        !widget.enabled ||
        _busy ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _busy = true;
    try {
      _pending ??= await updates.check();
      if (!mounted ||
          !widget.enabled ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      final update = _pending;
      final context = widget.navigatorKey.currentState?.overlay?.context;
      if (update == null || context == null || !context.mounted) return;
      _pending = null;
      updates.presented(update);
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.system_update_rounded),
          title: const Text('Update available'),
          content: Text(
            update.version == null
                ? 'A newer version of Stockfolio is available on Google Play.'
                : 'Stockfolio ${update.version} is available on the App Store.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Ignore'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Update now'),
            ),
          ],
        ),
      );
      if (accepted != true) {
        await updates.ignore(update);
      } else {
        var opened = false;
        try {
          opened = await updates.openStore(update);
        } catch (_) {
          /* Show recovery below. */
        }
        if (!opened && mounted && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not open the store. Please update Stockfolio from your app store.',
              ),
            ),
          );
        }
      }
    } catch (_) {
      // An optional update check must never interrupt sign-in or portfolio use.
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
