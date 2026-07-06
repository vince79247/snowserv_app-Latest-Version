# SnowServ — Pre-launch / Hardening Checklist

Living list of what must happen before real users, in rough priority order.
Status: ✅ done · 🔨 in progress · ⏳ todo · 🧊 later. "Needs you" = requires
Vince (Apple portal, decisions, etc.), not just code.

## Security hardening
- ✅ Firebase iOS API key restricted to bundle id (Google Cloud Console)
- ✅ Provider documents: private bucket + admin-only signed-URL viewing (admin-doc-url)
- ✅ Secrets server-side only (Stripe secret, service role, Firebase admin)
- 🔨 **Real admin authentication** — replace the shared client-side admin password
  with a real `profiles.is_admin` account; verify server-side in functions.
- 🧊 **Full RLS lockdown** — the app currently runs on permissive/loose row-level
  security. Tightening every table's policies so the DB enforces who-can-do-what
  is the big one: touches every flow (order, accept, payout, admin) and needs
  full re-testing. **Dedicated session right before launch — do not rush mid-build.**

## Auth / signup (conversion)
- ⏳ **Sign in with Apple** (+ optional Google). NOTE: Apple Guideline 4.8 — offering
  *any* social login forces Sign in with Apple too. Needs: Apple portal config
  (needs you), first-login provisioning of profiles/users/providers rows, and a
  "customer or provider?" step after social sign-in.

## Scale / reliability
- ⏳ **Storm-burst load test** — simulate a spike (k6 / Artillery) on order→dispatch;
  the real risk for this app is bursts during storms, not steady traffic. Do before launch.
- ⏳ **Database indexes** on hot paths: jobs(customer_id), jobs(status),
  jobs(dispatched_to), providers(user_id), service_areas(zips GIN).
- ⏳ **Supabase Pro plan** + watch metrics dashboard (CPU, connections, slow queries).
  Launch scale (one town) is tiny — scale the plan up as usage grows.

## Ops / admin
- ⏳ **Web admin** — `flutter build web` reuses the existing admin screen in a laptop
  browser (lowest effort). Prerequisite: real admin auth (a browser URL is exposed).
  Later option: purpose-built dashboard or a low-code tool (Retool) on Supabase.

## App Store submission (needs you)
- ⏳ Paste Privacy Policy URL into App Store Connect (privacy policy field)
- ✅ Domain owned: snowserv.app (Cloudflare) + support@snowserv.app (Zoho) live
- ⏳ **Android setup** (only if launching Android): google-services.json,
  applicationId com.snowserv.app (change from com.example — can't change after first
  upload), release signing keystore (back it up!), Android launcher icon, google-services plugin.

## Done recently (for reference)
- ✅ Authorize-and-capture payments (deployed); all edge functions deployed & current
- ✅ service_areas regional pricing + availability gate + pre-signup quote
- ✅ Storm pricing scale + rename
- ✅ Legal links in-app + sign-up consent
