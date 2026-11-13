import 'package:flutter/material.dart';
import 'biometric_session.dart';

Future<bool> confirmBiometricSetup(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use biometrics next time?'),
        content: const Text(
          'Anyone with a supported fingerprint or face enrolled on this device can unlock this account. '
          'Your password is not saved. You will need it again when your session expires.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enable'),
          ),
        ],
      ),
    ) ??
    false;

class BiometricUnlockScreen extends StatefulWidget {
  const BiometricUnlockScreen({
    super.key,
    required this.onUnlock,
    required this.onPassword,
  });
  final Future<void> Function() onUnlock, onPassword;
  @override
  State<BiometricUnlockScreen> createState() => _BiometricUnlockScreenState();
}

class _BiometricUnlockScreenState extends State<BiometricUnlockScreen> {
  bool busy = false;
  String? error;

  Future<void> unlock() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onUnlock();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is SessionUnlockException
              ? e.message
              : 'Unlock was cancelled or unavailable. Try again or use your password.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/app_icon/stockfolio_app_icon.png',
                    width: 64,
                    height: 64,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Stockfolio is locked',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: busy ? null : unlock,
                    icon: busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fingerprint),
                    label: const Text('Unlock with biometrics'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() => busy = true);
                            try {
                              await widget.onPassword();
                            } catch (_) {
                              if (mounted) {
                                setState(
                                  () => error =
                                      'Could not clear this session. Please try again.',
                                );
                              }
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    child: const Text('Use password instead'),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class BiometricSettingsTile extends StatefulWidget {
  const BiometricSettingsTile({
    super.key,
    required this.session,
    required this.onChanged,
  });
  final BiometricSession session;
  final Future<void> Function(bool) onChanged;
  @override
  State<BiometricSettingsTile> createState() => _BiometricSettingsTileState();
}

class _BiometricSettingsTileState extends State<BiometricSettingsTile> {
  late Future<bool> available = widget.session.available();
  bool busy = false;
  String? error;

  Future<void> change(bool enable) async {
    if (enable) {
      if (!await confirmBiometricSetup(context) || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onChanged(enable);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is SessionUnlockException
              ? e.message
              : 'Biometric setup was cancelled or unavailable. Your current setting is unchanged.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          available = widget.session.available();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.session.supported) return const SizedBox.shrink();
    return FutureBuilder<bool>(
      future: available,
      builder: (context, snapshot) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.fingerprint),
            title: const Text('Biometric unlock'),
            subtitle: Text(
              widget.session.enabled
                  ? 'On for this device'
                  : snapshot.data == true
                  ? 'Off for this device'
                  : 'No supported biometrics enrolled',
            ),
            value: widget.session.enabled,
            onChanged:
                busy || (snapshot.data != true && !widget.session.enabled)
                ? null
                : change,
          ),
          if (busy)
            const LinearProgressIndicator(
              semanticsLabel: 'Updating biometric setting',
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
