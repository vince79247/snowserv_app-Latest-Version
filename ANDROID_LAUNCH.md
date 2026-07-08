# Android Launch Checklist

Getting SnowServ (Flutter) to feature-parity with iOS on Android — push
notifications, location, and a publishable build. Work top-to-bottom; the
Firebase step depends on the package name being final first.

Legend: **[you]** needs your action (console / decision / secret) · **[claude]**
I can do in the repo · ✅ done.

## 1. Identity & signing
- [x] **[claude]** Package name set to `com.snowserv.app` (was `com.example.snowserv_app`).
      namespace + applicationId + MainActivity moved. — done, commit `<pending>`.
- [ ] **[you]** Generate a **release keystore** (one-time) and keep the passwords safe:
      `keytool -genkey -v -keystore ~/snowserv-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias snowserv`
- [ ] **[claude]** Wire `android/key.properties` + release `signingConfig` in Gradle
      (and gitignore the keystore + key.properties). Do AFTER you make the keystore.

## 2. Firebase Android app (unlocks FCM push)
- [x] **[claude]** Android app registered in Firebase (`com.snowserv.app`,
      App ID `1:444628528819:android:ee770347be46998f2b4ac6`) via the Firebase CLI.
- [x] **[claude]** `google-services.json` in `android/app/` (committed).
- [x] **[claude]** `com.google.gms.google-services` Gradle plugin applied.
- [x] **[claude]** White snowflake `ic_notification` drawable + navy tint meta-data.

## 3. Permissions (Android 13+)
- [x] **[claude]** `POST_NOTIFICATIONS` declared (no notifications without it). — done.
- [x] **[claude]** `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` declared. — done.
- [ ] **[claude/you]** Confirm the app requests POST_NOTIFICATIONS at runtime on
      Android 13+ (firebase_messaging `requestPermission()` handles this; verify on device).

## 4. Build & verify
- [x] **[claude]** Debug APK **builds** with Firebase wired in. Required fixing a
      ~2021-stale `pubspec.lock` (transitive plugins used `jcenter()`, removed in
      Gradle 9) via `flutter pub upgrade` — 93 deps refreshed, no Dart errors.
- [ ] **[you+claude]** `flutter run -d <android device/emulator>` — verify launch,
      login, order, dispatch, and a **real push job offer** landing on Android.
      (Needs a physical Android phone or an emulator — none connected yet.)

## 5. Play Store prep (later)
- [ ] **[you]** Google Play Developer account ($25 one-time).
- [ ] **[claude]** `flutter build appbundle` config, versioning, store listing assets.
- [ ] **[you]** Privacy policy URL, data-safety form, screenshots.

---
## Known cross-platform issues found in the audit (not Android-specific)
- [ ] Dispatch **countdown vs cron**: UI offer window 4 min, cron expires at 3 min
      (1-min granularity softens it). Reconcile so a provider can't accept an
      already-expired offer.
- [ ] Delete legacy unused edge functions `create-payment-intent`,
      `get-payment-methods` (Checkout migration made them dead — CLAUDE.md confirms).
- [ ] `dart:io` File usage in provider screens is mobile-only-safe; audit `kIsWeb`
      guards if those flows ever render on web.

## Architecture direction (going forward)
- Route DB access through a **service/repository layer** (`lib/services/`), not
  `supabase.from(...)` in widgets. Migrate incrementally as screens are touched.
