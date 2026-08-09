# Google Play — Data Safety answers (SnowServ)

Drafted 2026-08-09 against the **actual** schema, the packages in `pubspec.yaml`, the
Android manifest, and the live privacy policy at https://snowserv.app/privacy.

> **These answers must match the privacy policy.** A mismatch is a rejection. The policy
> was corrected on 2026-08-09 (it previously claimed we collect driver's license images
> and SSNs — we collect neither), so the two are consistent as of that date. If either
> changes, change both.

---

## The one definition people get wrong: "Shared"

Google: *"Sharing refers to transferring user data collected from your app to a **third
party**."* It **excludes** transfer to a service provider that processes data on your
behalf.

Supabase, Stripe, Firebase, and Resend are all **service providers / processors** for
SnowServ. So the honest answer to "Is this data shared?" is **No** for every row below.

Do not answer "Yes" out of caution. Over-declaring sharing is not the safe option — it
implies you sell or hand data to unrelated parties, which is a different and worse claim
than the truth.

## Payment card numbers: we do NOT collect them

Card entry happens on **Stripe's hosted Checkout page**, not in our app. The card number
never touches SnowServ. What we store is what Stripe's webhook mirrors back: **brand,
last four digits, expiry month/year** (`users.card_*`) plus a Stripe customer/payment
reference.

That is still declarable as "Payment info" — but the distinction matters if Google ever
asks, and it matches the privacy policy wording ("We do not store full card numbers").

---

## Section 1 — Data collection & security (asked first)

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **Yes** |
| Is all of the user data collected by your app encrypted in transit? | **Yes** — all traffic is HTTPS/TLS (Supabase, Stripe, Firebase, Resend) |
| Do you provide a way for users to request that their data be deleted? | **Yes** — in-app account deletion (Account menu → Delete account), backed by the `delete-account` edge function, which scrubs PII, purges storage objects, detaches the Stripe card, and deletes the auth user |

Deletion was built for **App Store Guideline 5.1.1(v)** and satisfies Play's requirement
too. It is in-app, so no separate deletion URL is required — but if the form insists on
one, use `https://snowserv.app/privacy`.

---

## Section 2 — Data types

For every row: **Shared = No**, and **Ephemeral = No** (it is stored) unless noted.

### Location
| Type | Collected | Required? | Purposes | Notes |
|---|---|---|---|---|
| Approximate location | **Yes** | Required | App functionality | The service address is geocoded to lat/lng to decide which pricing zone it falls in and whether we serve it at all |
| Precise location | **Yes** | **Optional** (permission-gated) | App functionality; Fraud prevention, security, and compliance | Provider GPS only: live position while online for job matching, plus a one-shot fix at Start and Complete recorded as distance-to-job. Customers never provide GPS |

The fraud/security purpose on precise location is accurate and worth declaring — the
start/complete distances exist to verify a provider was actually on site.

### Personal info
| Type | Collected | Required? | Purposes |
|---|---|---|---|
| Name | **Yes** | Required | App functionality; Account management |
| Email address | **Yes** | Required | App functionality; Account management; Developer communications |
| User IDs | **Yes** | Required | App functionality; Account management |
| Address | **Yes** | Required | App functionality |
| Phone number | **Yes** | Required | App functionality; Account management |
| Other info | **Yes** | Optional | App functionality | Providers only: equipment, insurance carrier/policy/expiry, vehicle details |

**Do NOT declare:** race/ethnicity, political or religious beliefs, sexual orientation,
or any government ID. We collect none of them — the identity step was removed on
2026-08-07 and Stripe performs identity verification during payout onboarding.

### Financial info
| Type | Collected | Required? | Purposes |
|---|---|---|---|
| User payment info | **Yes** | Required | App functionality | Card brand, last four, expiry — mirrored from Stripe. Never the full card number |
| Purchase history | **Yes** | Required | App functionality | Jobs booked, services selected, prices paid |

**Do NOT declare** credit score or "other financial info."

### Photos and videos
| Type | Collected | Required? | Purposes |
|---|---|---|---|
| Photos | **Yes** | Required (for providers completing a job) | App functionality; Fraud prevention, security, and compliance |

Camera-only. A completion photo is required as proof of work and is shown to that job's
customer; an optional "before" photo can be taken at Start.

### Device or other IDs
| Type | Collected | Required? | Purposes |
|---|---|---|---|
| Device or other IDs | **Yes** | Optional (notification permission) | App functionality | Firebase Cloud Messaging registration token, stored on the profile, used to deliver job offers and status pushes |

### Everything else — answer NO
Health and fitness · Financial info beyond the two rows above · Messages (SMS, email, or
other in-app messages) · Audio · Files and docs · Calendar · Contacts · App activity
(interactions, search history, installed apps, other user-generated content) · Web
browsing history · **App info and performance (crash logs, diagnostics, other)**.

**No crash or diagnostics reporting exists** — there is no Crashlytics, no Analytics, no
Sentry in `pubspec.yaml`. Only `firebase_core` and `firebase_messaging`, which are push
only. Do not declare diagnostics you do not collect.

> **Judgment call — "Messages / other in-app messages":** users type a free-text
> description when filing a dispute, and providers type job notes. These are support and
> operational records rather than person-to-person messaging, so the draft answers **No**.
> If Google ever queries it, "Other user-generated content" would be the honest
> reclassification. Flagging it rather than hiding it.

---

## Android permissions — one thing to check before submitting

Declared in `android/app/src/main/AndroidManifest.xml`:

`INTERNET` · `CAMERA` · `READ_MEDIA_IMAGES` · `POST_NOTIFICATIONS` ·
`ACCESS_FINE_LOCATION` · `ACCESS_COARSE_LOCATION`

⚠️ **`READ_MEDIA_IMAGES` looks unnecessary.** Photo capture is camera-only — Gallery
selection was deliberately removed on 2026-07-13 so completion photos are genuine
proof-of-work. The permission is most likely injected by `image_picker`'s manifest
merger rather than requested by our code. Declaring photo-library access an app never
uses is the kind of thing that draws a policy question. Worth confirming and, if it is
ours, removing with `tools:node="remove"` before the first submission.

---

## Sources for every answer above
* Schema and columns: `CLAUDE.md` → Database tables
* Packages: `pubspec.yaml`
* Permissions: `android/app/src/main/AndroidManifest.xml`
* Deletion: `lib/utils/account_deletion.dart` → `supabase/functions/delete-account/`
* Location capture: provider Start/Complete, `jobs.start_distance_m` / `complete_distance_m`
* Photos: `job-photos` storage bucket, `jobs.completion_photos` / `before_photos`
* Live policy: https://snowserv.app/privacy
