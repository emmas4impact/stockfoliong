import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionUnlockException implements Exception {
  const SessionUnlockException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class SessionVault {
  Future<String?> read({required bool biometric});
  Future<void> write(String token, {required bool biometric});
  Future<void> delete({required bool biometric});
}

class DeviceSessionVault implements SessionVault {
  DeviceSessionVault(String scope)
    : regular = FlutterSecureStorage(
        aOptions: AndroidOptions(storageNamespace: 'stockfolio.session.$scope'),
        iOptions: IOSOptions(
          accountName: 'stockfolio.session.$scope',
          accessibility: KeychainAccessibility.unlocked_this_device,
        ),
      ),
      protected = FlutterSecureStorage(
        aOptions: AndroidOptions.biometric(
          storageNamespace: 'stockfolio.biometric.$scope',
          enforceBiometrics: true,
          requireBiometricsPerOperation: true,
          biometricType: AndroidBiometricType.strongBiometricOnly,
          biometricPromptTitle: 'Unlock Stockfolio',
          biometricPromptSubtitle:
              'Confirm your identity to access your account',
          biometricPromptNegativeButton: 'Cancel',
        ),
        iOptions: IOSOptions(
          accountName: 'stockfolio.biometric.$scope',
          accessibility: KeychainAccessibility.passcode,
          accessControlFlags: const [AccessControlFlag.biometryCurrentSet],
        ),
      );

  final FlutterSecureStorage regular, protected;
  FlutterSecureStorage _store(bool biometric) =>
      biometric ? protected : regular;
  @override
  Future<String?> read({required bool biometric}) =>
      _store(biometric).read(key: 'access_token');
  @override
  Future<void> write(String token, {required bool biometric}) =>
      _store(biometric).write(key: 'access_token', value: token);
  @override
  Future<void> delete({required bool biometric}) =>
      _store(biometric).delete(key: 'access_token');
}

class BiometricSession {
  BiometricSession(
    String baseUrl, {
    SessionVault? vault,
    bool? supported,
    Future<bool> Function()? canAuthenticate,
  }) : supported =
           supported ??
           (!kIsWeb &&
               (defaultTargetPlatform == TargetPlatform.android ||
                   defaultTargetPlatform == TargetPlatform.iOS)),
       scope = base64Url.encode(
         utf8.encode(baseUrl.replaceAll(RegExp(r'/+$'), '')),
       ),
       _canAuthenticate = canAuthenticate ?? _deviceCanAuthenticate {
    _vault = vault ?? DeviceSessionVault(scope);
  }

  final bool supported;
  final String scope;
  final Future<bool> Function() _canAuthenticate;
  late final SessionVault _vault;
  bool enabled = false;
  bool prompting = false;
  String get modeKey => 'native_session_mode.$scope';

  static Future<bool> _deviceCanAuthenticate() async {
    final auth = LocalAuthentication();
    final enrolled = await auth.getAvailableBiometrics();
    return defaultTargetPlatform == TargetPlatform.android
        ? enrolled.contains(BiometricType.strong)
        : enrolled.isNotEmpty;
  }

  Future<bool> available() async {
    if (!supported) return false;
    try {
      return await _canAuthenticate();
    } catch (_) {
      return false;
    }
  }

  Future<String?> restore() async {
    if (!supported) return null;
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(modeKey);
    enabled = mode == 'biometric';
    if (enabled) {
      await prefs.remove('access_token');
      return null; // Only unlock() may read the biometric-protected token.
    }
    if (mode == 'signed_out') return null;
    if (mode == 'password') return _vault.read(biometric: false);
    final legacy = prefs.getString('access_token');
    if (legacy != null) {
      await savePasswordSession(legacy);
      return legacy;
    }
    // Do not resurrect iOS Keychain sessions after reinstall (preferences are gone).
    return null;
  }

  Future<void> savePasswordSession(String token) async {
    final prefs = await SharedPreferences.getInstance();
    final wasEnabled = enabled;
    await prefs.setString(modeKey, 'signed_out');
    enabled = false;
    await _vault.write(token, biometric: false);
    await prefs.remove('access_token');
    if (wasEnabled) {
      try {
        await _vault.delete(biometric: true);
      } catch (_) {
        /* The signed-out marker prevents reuse. */
      }
    }
    await prefs.setString(modeKey, 'password');
  }

  Future<T> _withPrompt<T>(Future<T> Function() operation) async {
    if (prompting) {
      throw const SessionUnlockException(
        'Authentication is already in progress.',
      );
    }
    prompting = true;
    try {
      return await operation();
    } finally {
      prompting = false;
    }
  }

  Future<void> enable(String token) async {
    if (!await available()) {
      throw const SessionUnlockException(
        'No supported biometrics are enrolled on this device.',
      );
    }
    await _withPrompt(() async {
      await _vault.write(token, biometric: true);
      if (await _vault.read(biometric: true) != token) {
        throw const SessionUnlockException(
          'Biometric storage could not be verified.',
        );
      }
      await _vault.delete(biometric: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('access_token');
      await prefs.setString(modeKey, 'biometric');
      enabled = true;
    });
  }

  Future<String?> unlock() => _withPrompt(() async {
    if (!enabled || !supported) return null;
    return _vault.read(biometric: true);
  });

  Future<void> disable(String currentToken) => _withPrompt(() async {
    if (!enabled) return;
    if (await _vault.read(biometric: true) != currentToken) {
      throw const SessionUnlockException(
        'Please sign in with your password again.',
      );
    }
    try {
      await _vault.write(currentToken, biometric: false);
      await _vault.delete(biometric: true);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(modeKey, 'password');
      enabled = false;
    } catch (_) {
      await _vault.delete(biometric: false);
      rethrow;
    }
  });

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(modeKey, 'signed_out');
    await prefs.remove('access_token');
    final wasEnabled = enabled;
    enabled = false;
    // Logout must remain possible after biometric lockout or invalidated device keys.
    for (final biometric in [false, if (wasEnabled) true]) {
      try {
        await _vault.delete(biometric: biometric);
      } catch (_) {
        /* Never restore after signed_out. */
      }
    }
  }
}
