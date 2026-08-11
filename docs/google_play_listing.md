# Google Play listing + submission pack — SnowServ (Android)

Copy-paste source for the Google Play Console. Draft by Claude 2026-07-17. Mirrors
the iOS pack (docs/app_store_listing.md) with Play-specific pieces (Data safety,
content rating, permissions declaration). Fields marked **[YOU]** need your action.

Account decision (2026-07-17): registering as an **organization** using the **D-U-N-S
number Vince now has** → skips the 20-tester/14-day rule that new personal accounts face.

---

## 1. Store listing — text
- **App name** (30 char max): `SnowServ`
- **Short description** (80 char max):
  > On-demand snow removal — book a local pro to clear your driveway in a tap.
- **Full description** (4000 char max):
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
• Your card is only placed on hold when you book — you're not charged until a provider
  actually starts the work. Cancel before that and the hold is released.

WHY SNOWSERV
• Vetted, local providers.
• No contracts. No monthly fees. No hidden fees.
• Secure payment powered by Stripe.
• Real-time updates and notifications from request to completion.

DRIVE WITH SNOWSERV
Have a plow truck or just a reliable shovel? Sign up as a provider, get matched to nearby
jobs, and keep the majority of every job — with fast payouts to your bank.

Now serving Yonkers, NY — with more of Westchester County on the way.
If we're not in your neighborhood yet, join the waitlist in the app and we'll let you
know when we arrive.

Questions? support@snowserv.app
```

## 2. Categorization
- **App category:** House & Home  *(alt: Lifestyle — House & Home is the better fit for
  an on-demand home service)*
- **Tags:** snow removal, home services, on-demand (pick from Play's tag list)
- **Content rating:** Everyone (see §6)

## 3. Graphic assets  **[YOU — mostly]**
- **App icon:** 512 × 512 PNG — already have the navy snowflake icon (reuse it exported at 512).
- **Feature graphic:** 1024 × 500 PNG — **required by Play, needs to be created** (a simple
  branded banner: snowflake + "SnowServ — On-demand snow removal" on the frost/navy palette).
- **Phone screenshots:** 2–8, min 320px, 16:9 or 9:16. **Reuse the iOS captures** in
  ~/Desktop/SnowServ-AppStore-Screenshots (the 1290×2796 ones work fine for Play too).

## 4. Contact details + URLs
- **Email:** support@snowserv.app
- **Website:** https://snowserv.app
- **Privacy policy:** https://snowserv.app/privacy  (LIVE)

## 5. Data safety form  ← Play's version of Apple's privacy labels (fill in the Console UI)
Declare data COLLECTED (all "collected", processed on our servers; encrypted in transit; a
user CAN request deletion — in-app account deletion exists):
- **Personal info:** Name, Email address, Phone number — *App functionality, Account management.*
- **Location:** Approximate + Precise location — *App functionality* (price by area + dispatch
  the nearest provider). Foreground only; no background location.
- **Financial info:** Payment handled by **Stripe**; the app stores only card brand + last-4 as
  a "card on file" indicator (not full card numbers). Purchase history (jobs).
- **Photos:** completion/"before" photos (provider-captured proof-of-work).
- **App activity / IDs:** User ID; push token (for notifications).

Data SHARED with third parties:
- **Stripe** — payment processing (a service provider; payment details go directly to Stripe).
- The customer's service **address is shown to the assigned provider** so they can do the job.

Security: **Data is encrypted in transit.** Users can **request account + data deletion**
in-app (Account menu → Delete Account). **No data is used for advertising or sold.**

## 6. Content rating questionnaire (IARC)
- No violence, sexual content, profanity, gambling, drugs, or user-to-user unmoderated
  content of a mature nature → rating comes out **Everyone**.
- Does the app share the user's location with other users? YES — the customer's address is
  shared with the assigned provider to perform the service (answer truthfully).

## 7. Target audience & content
- **Target age:** 18+ (it's a paid home service; not directed at children). No child-directed
  content. No ads.

## 8. Permissions — declaration
- **ACCESS_FINE_LOCATION / ACCESS_COARSE_LOCATION** — price jobs by area + dispatch the nearest
  provider. **Foreground / "while in use" only — NO background location** (so no background-
  location review/video is required). Ordering also works by typing an address.
- **POST_NOTIFICATIONS** — job status updates (assigned / started / completed).
- **CAMERA** — providers photograph completed work (proof-of-work); customers don't need it to order.
- No SMS/Call-log/Contacts permissions.

## 9. App access (login for Google's reviewers)  — same as the iOS demo
Parts of the app require an account, so provide a login in **App content → App access**:
```
DEMO ACCOUNT (customer)
  Email:    support@snowserv.app
  Password: SnowServReview1

Payments run in Stripe TEST mode for review — pay with card 4242 4242 4242 4242,
any future expiry, any CVC. Booking places an authorization HOLD (card not charged).

HOW TO TEST
1. Enter the demo email + password and tap Log In. There is NO customer/provider
   choice to make — the app routes you to the right home automatically (this account
   lands on the customer home).
2. The saved address is in Yonkers, NY (a served area).
3. Choose a service and order; pay with the test card above; the order shows as active.
```
(Demo login re-verified working 2026-07-28 against the live DB — HTTP 200. Login flow
updated build 12: the Customer/Provider tab was removed from login, so the old
"Customer tab" step no longer applies — see docs/app_store_listing.md for iOS.)

## 10. Payments policy
SnowServ charges for a **real-world, physical service** (a provider physically clears the
property), processed by **Stripe**. Per Google Play's Payments policy, **Google Play Billing
is NOT required** for physical goods/services — external payment (Stripe) is allowed. There
are no digital goods or in-app purchases. No lending, investing, or other regulated financial
products → the "Financial features" declaration is answered accordingly (none).

---

## What's DONE vs. what needs YOU
DONE (in repo): package `com.snowserv.app`, Firebase/FCM wired, permissions declared, a
release **app bundle builds** (`flutter build appbundle` → 58 MB .aab), release **signing
wired** (needs your keystore — see android/key.properties.example), privacy policy LIVE.

NEEDS YOU:
- [ ] Create the **Play Console developer account** ($25), register as **Organization** with
      your **D-U-N-S number**.
- [ ] Generate the **release keystore** (one `keytool` command) + fill android/key.properties.
- [ ] Create the **feature graphic** (1024×500).
- [ ] Fill **Data safety** (§5) + **content rating** (§6) in the Console.
- [ ] Upload the **.aab** and the screenshots; paste §1–§10.
- [ ] **Test the app on a real Android device** first (it's never been run on Android — the
      one true prerequisite; iOS-verified only so far).

## Not required (so we don't chase them)
- Google Play Billing — not needed (real-world service; Stripe is allowed).
- Separate Android privacy policy — the snowserv.app/privacy page covers both platforms.
