# App Store listing + submission pack — SnowServ (iOS)

Copy-paste source for App Store Connect. Drafts by Claude 2026-07-11; review before
pasting. Fields marked **[YOU]** need something only Vince can provide.

---

## 1. App name & subtitle
- **App Name** (30 char max): `SnowServ`
- **Subtitle** (30 char max): `On-demand snow removal`

## 2. Promotional text (170 char max — editable anytime, no review)
> Winter's here. Book a vetted local pro to clear your driveway, walkway, or salt the
> ice — right from your phone. Upfront pricing, no contracts, no hidden fees.

## 3. Description (App Store body)
```
Snow removal, on demand.

SnowServ connects you with vetted local snow-removal pros — so you can skip the shovel
and book help in a couple of taps. Driveway buried? Walkway iced over? Request service
from your phone and a nearby provider takes care of it.

HOW IT WORKS
• Enter your address and pick what you need — driveway, walkway, or both, plus optional
  de-icing/salting.
• See your price upfront before you book. No surprises.
• A vetted local provider is dispatched to you.
• Track your job and get notified when it's done. Rate your provider when it's complete.

UPFRONT, HONEST PRICING
• You see the full price before you order.
• During storms, pricing adjusts with snow depth — and we show you exactly how, so you
  always know why a price is what it is.
• Your card is only an authorization hold when you book — you're not charged until a
  provider actually starts the work. Cancel before that and the hold is released.

WHY SNOWSERV
• Vetted, local providers.
• No contracts. No monthly fees. No hidden fees.
• Secure payment powered by Stripe (Apple Pay supported where available).
• Real-time updates and notifications from request to completion.

Now serving Yonkers and nearby Westchester County, NY — with more areas on the way.
If we're not in your neighborhood yet, join the waitlist in the app and we'll let you
know when we arrive.

Questions? support@snowserv.app
```

## 4. Keywords (100 char max, comma-separated, NO spaces)
```
snow removal,snow plowing,driveway,shoveling,snow shovel,salting,deicing,plow,winter,local pro
```

## 5. Category
- **Primary:** Lifestyle  *(alt: Utilities — Lifestyle is the better fit for an
  on-demand local service)*
- **Secondary:** Utilities

## 6. URLs
- **Support URL:** https://snowserv.app  (or a support page; support@snowserv.app is live)
- **Marketing URL:** https://snowserv.app
- **Privacy Policy URL:** https://snowserv.app/privacy  (LIVE — verified HTTP 200, 2026-07-17)
- **Terms of Service URL** (if the form asks): https://snowserv.app/terms  (LIVE)
  - NOTE: the IN-APP legal links (lib/utils/legal.dart) still point to the older
    Google-Docs copies of these. A 2-line update to the snowserv.app pages should ride
    the next app build for consistency — not a submission blocker (the Google-Docs
    links still open fine).

## 7. App Review notes  ← the most important part for avoiding rejection
```
ABOUT THE APP
SnowServ is an on-demand marketplace for real-world snow-removal services (a provider
physically clears the customer's property). It is NOT digital content.

PAYMENTS
Payments are processed by Stripe because this is a physical, real-world service —
per App Store Review Guideline 3.1.3(e)/3.1.5(a), Apple In-App Purchase does not apply.
The app is currently in Stripe TEST MODE for review. Use this test card on the Stripe
checkout page:
  Card: 4242 4242 4242 4242   Exp: any future date   CVC: any 3 digits   ZIP: any
Booking places an AUTHORIZATION HOLD — the card is not actually charged during review.

DEMO ACCOUNT (customer)
  Email:    support@snowserv.app
  Password: SnowServReview1

HOW TO TEST (customer flow)
1. Enter the demo email + password and tap Log In (no role to pick — the app routes
   automatically; this account lands on the customer home).
2. Add a service address in Yonkers, NY (e.g. any Yonkers street address) — the app
   geocodes it to confirm we serve that area and to price the job.
3. Choose a service (e.g. Driveway) and tap to order.
4. On the Stripe checkout page, pay with the test card above.
5. The order appears on the home screen as an active job.

LOCATION
The app requests location to price jobs by area and to dispatch the nearest provider.
Ordering also works by entering an address manually.

TWO ROLES
The app has a customer side and a provider (contractor) side, chosen at sign-up.
Providers are vetted and approved before they can accept work (like a driver app).
Reviewers only need the customer flow above to see core functionality. A provider demo
account can be supplied on request if you'd like to see the accept/complete side.

Contact: support@snowserv.app
```

## 8. App Privacy questionnaire (what to declare in App Store Connect)
Data collected and linked to the user's identity:
- **Contact Info:** name, email, phone (account).
- **Location:** precise location (pricing + dispatch). Used for App Functionality.
- **Financial Info:** payment handled by Stripe; app stores card brand/last-4 as a
  "card on file" indicator (not full card data). Purchase history (jobs).
- **Identifiers:** user ID; device push token (FCM/APNs) for notifications.
- **Usage/Diagnostics:** only if you add analytics/crash reporting (none required today —
  declare only what's actually present).
Data use: App Functionality (and Notifications). **Not** used for tracking/ads.
Declare "Data is NOT used to track you" (no third-party ad tracking).

## 9. Age rating
- **4+** (no objectionable content).

## 10. Export compliance
- Uses only standard HTTPS/TLS encryption → qualifies for the standard exemption.
  Answer the encryption question accordingly (no custom/proprietary crypto). Add
  `ITSAppUsesNonExemptEncryption = false` to Info.plist to skip the prompt each upload.

## 11. Screenshots — shot list  **[YOU — capture these]**
Required at least for 6.7" iPhone (App Store will scale for others). Capture 4–6 of:
1. Service selector / home (pick driveway·walkway·salting) — the core value prop.
2. Upfront price screen (and the storm-pricing scale, to showcase pricing transparency).
3. Active job / tracking screen.
4. Order history / receipt.
5. (Optional) provider "available jobs" screen — shows the two-sided marketplace.
Tip: use a clean demo account with realistic sample data; hide any real personal info.

---

## Pre-submission verification (Claude, 2026-07-17 — tested against the LIVE DB)
The demo review path was re-checked end-to-end after the RLS lockdown + signup-trigger
changes, since a broken demo login is the #1 rejection cause:
- ✅ **Demo login works** — `support@snowserv.app / SnowServReview1` authenticates against
  the live auth endpoint and issues a token. Account is a **confirmed customer**.
- ✅ **Yonkers service zone is ACTIVE** with a polygon (5 vertices) + zip fallback and live
  pricing (driveway $120 / both $160 / salting $45) — so the reviewer's Yonkers test
  address will price and order (won't hit "not available in your area").
- ✅ **Stripe is in TEST mode**; the 4242… test card + the manual-capture hold flow are
  what the reviewer note describes. (Webhook → job-create verified earlier in the build.)
- ℹ️ No provider is online, which is fine: the customer flow places the order and it shows
  as an active job regardless. Provider-side demo is offered "on request" in the notes.

## What's DONE vs. what needs YOU
DONE (in repo / already set up): app name, bundle id com.snowserv.app, icon+splash,
working iOS Stripe Checkout, **privacy policy + terms published (snowserv.app/privacy,
/terms — LIVE)**, export-compliance exemption declared, demo review account verified.

NEEDS YOU:
- [x] Demo review account (customer): support@snowserv.app / SnowServReview1 — **verified
      working 2026-07-17** (authenticates + confirmed customer).
- [ ] Capture **screenshots** (§11) — the one thing only you can do (needs the app running).
- [ ] Create the app record in **App Store Connect** and paste §1–§10.
- [ ] Upload **build 7** (Face ID + live-location fixes) via Xcode, then submit for review.
- [ ] (Optional) If you want the reviewer to see the provider side too, create one provider
      login and I'll approve + position it in Yonkers so a test order dispatches live.

## Not required (so we don't chase them)
- Sign in with Apple: only required if we add social login (Google/Facebook). We use
  email/password only, so it's NOT triggered.
- LIVE Stripe: NOT needed for submission/approval — that's the business-launch gate
  (needs LLC/EIN). Test mode + the reviewer note above is fine for review.
```
