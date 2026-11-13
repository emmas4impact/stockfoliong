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
