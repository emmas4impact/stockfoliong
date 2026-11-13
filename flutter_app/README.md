# flutter_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Mobile Biometric Unlock

Android and iOS users can enable **Profile > Biometric unlock** after signing in
with their password. Web sign-in is unchanged. This protects an existing session;
it does not replace server authentication or extend the token's expiry.

Mobile session tokens use Keychain/Keystore storage. Opting in moves the token to
biometric-protected storage; the app locks on restart or when backgrounded. A
successful unlock also verifies the session with the API. Expired sessions,
changed biometric enrollment, and unavailable device keys require password
sign-in. No passwords or biometric templates are stored by the app.

No API deployment, database migration, or additional server key is needed for
this feature. Ship updated native app builds. Android requires an enrolled strong
biometric supported by the device's secure storage; iOS supports Face ID/Touch ID.

Before release, test on physical Android and iOS devices:

- Enable and disable the setting; cancel and fail biometric prompts.
- Restart, background, resume, and inspect the app switcher for hidden account data.
- Change enrolled biometrics and confirm password fallback still works.
- Test expired sessions, offline unlock, logout, and switching accounts.
- Upgrade an existing installation and confirm its session migrates from preferences.
