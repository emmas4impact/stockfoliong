# Android Release Signing

This project is set up to use a real Android release keystore when
`flutter_app/android/key.properties` is present.

## 1. Create an upload keystore

Run:

```bash
keytool -genkeypair \
  -v \
  -keystore ~/upload-keystore.jks \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -alias upload
```

Keep the keystore and passwords safe.

## 2. Create `key.properties`

Copy:

```bash
cp flutter_app/android/key.properties.example flutter_app/android/key.properties
```

Then replace the placeholder values:

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=upload
storeFile=/absolute/path/to/upload-keystore.jks
```

`key.properties` is already ignored by git.

## 3. Build release flavors

### Staging release APK

```bash
flutter build apk --release --flavor staging
```

### Production release APK

```bash
flutter build apk --release --flavor production
```

### Production Play Store bundle

```bash
flutter build appbundle --release --flavor production
```

## 4. Important behavior

- If `key.properties` is present, Gradle uses the real release keystore.
- If `key.properties` is missing, release builds fall back to the debug key so
  local testing still works.
- For Play Store uploads, always build with the real release keystore.

## 5. Optional update prompt

The mobile app checks the installed user's Google Play update availability at
launch and on resume (at most once every six hours per app process). It offers
Update now, which opens the Play listing, or Ignore, which remembers that release
on this device. A later version code can prompt again. Store/network failures do
not block sign-in. No API setting or database migration is required.

Ship a build containing this feature first. An older installed build without the
feature cannot display the prompt. Then:

1. Install that build from Play using an enrolled internal tester account.
2. Publish a second signed build with a higher version code to that tester's
   track. Uploading a draft alone is not enough.
3. Wait for Play to make it available, then reopen the older app. For a fresh
   check inside the six-hour window, fully terminate and reopen it.
4. Confirm Ignore leaves the app usable and suppresses that release after restart.
   Test Update now on another device or a subsequent higher-code release.

The Play service decides account, track and rollout eligibility. Sideloaded APKs
and simulators may not support this check. The app does not download APKs or
force installation. See [Google's testing guide](https://developer.android.com/guide/playcore/in-app-updates/test).

On iOS, the same prompt compares the installed version with the App Store listing
for the bundle ID and opens that listing. The lookup uses the device locale's
country (NG if absent); builds can override it with
`--dart-define=APP_STORE_COUNTRY=NG`. Locale country is not guaranteed to match
the user's Apple storefront. There is no prompt without a matching published
listing, and App Store availability/compatibility still applies. TestFlight builds
are updated through TestFlight, not detected as new releases by this feature.
