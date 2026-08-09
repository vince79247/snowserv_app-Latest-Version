# Android Launch Checklist

Getting SnowServ (Flutter) to feature-parity with iOS on Android — push
notifications, location, and a publishable build. Work top-to-bottom; the
Firebase step depends on the package name being final first.

Legend: **[you]** needs your action (console / decision / secret) · **[claude]**
I can do in the repo · ✅ done.

## 1. Identity & signing
- [x] **[claude]** Package name set to `com.snowserv.app` (was `com.example.snowserv_app`).
      namespace + applicationId + MainActivity moved. — done, commit `<pending>`.
- [x] **[you]** **Release keystore DONE** (verified 2026-08-09). `android/key.properties`
      exists with all four values, the keystore file it points to is present, and it is
      correctly gitignored. Release bundles will be properly signed.
      ⚠️ **Those passwords are unrecoverable.** Lose them and you can never publish an
      update to this app — Play rejects a bundle signed with a different key, forever.
      They should be in a password manager, not only on this Mac.
- [x] **[claude]** Wired release `signingConfig` in Gradle to read from
      `android/key.properties` (gitignored) with a debug-key fallback so builds don't
      break pre-keystore; added `key.properties.example` template. — done 2026-07-17.

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
- [ ] **[you+claude]** Smoke-test on Android. **Two emulators already exist on this
      Mac** — `snowserv_pixel` and `snowserv_pixel2`, both Google Play images — so this
      does NOT need a physical phone and does NOT need to wait for anything:
      `flutter emulators --launch snowserv_pixel` then `flutter run -d emulator-5554`.
      Covers: launch, signup + role choice, all 4 registration steps, payouts gate,
      admin panel, push.
      ⚠️ **Stripe Checkout will fail on an emulator** — ~50% packet loss to Stripe
      produces "Something went wrong". That is the emulator, not a bug. Do not chase it.
- [ ] **[you]** FINAL hardware verification on a real Android phone (Tony's) — the
      only part that genuinely needs someone in the US with a handset: a real Checkout
      payment and a real GPS dispatch.

## 5. Play Store prep
- [x] **[you]** **Play Developer account DONE.** Organization account (Account ID
      7712496467828841866), D-U-N-S obtained, and as of 2026-08-08 organization
      verification, **website verification**, and **phone verification** all cleared.
      ⚠️ The public developer profile still shows Vince's HOME address, his admin-login
      email, and his personal cell. Decided 2026-08-09 to leave the address for now; the
      email and phone swaps are queued for October (Google Voice is US-only at signup).
- [x] **[claude]** `flutter build appbundle` VERIFIED — produces a release `.aab`
      (58 MB) cleanly. 2026-07-17. (Debug-signed until key.properties exists; §1.)
- [ ] **[claude]** Store listing assets + data-safety form draft (can reuse the iOS
      App Store listing copy).
- [ ] **[you]** Privacy policy URL (have it: snowserv.app/privacy), screenshots, submit.

---
## Known cross-platform issues found in the audit (not Android-specific)
- [x] Dispatch **countdown vs cron** — RESOLVED. Both now read
      `app_settings.dispatch_timeout_seconds` (default 240s), so the UI countdown and
      the pg_cron expiry cannot drift. Admin-editable from the Jobs tab.
- [x] Delete legacy unused edge functions — DONE 2026-07-29. `create-payment-intent`
      and `get-payment-methods` are gone (the latter also leaked another customer's
      card brand/last4 with no ownership check).
- [ ] `dart:io` File usage in provider screens is mobile-only-safe; audit `kIsWeb`
      guards if those flows ever render on web.

## Architecture direction (going forward)
- Route DB access through a **service/repository layer** (`lib/services/`), not
  `supabase.from(...)` in widgets. Migrate incrementally as screens are touched.
