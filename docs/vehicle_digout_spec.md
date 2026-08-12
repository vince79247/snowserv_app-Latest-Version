# Vehicle dig-out — build spec

**Status:** approved, NOT started. Written 2026-08-12 to be built after the
store builds are through and real orders are flowing. Target: live for January.

**Decision (Vince, 2026-08-12):** ship the three existing services, get real
orders, then add this. It is an **add-on**, not a replacement for Sidewalk Only.

---

## 1. What we're selling

A street-parked (or driveway-parked) car walled in by snow — usually by the city
plow berm — cleared so the customer can get to work.

This reaches a customer we currently **cannot serve at all**: the renter with no
driveway and no sidewalk duty, who today has nothing to buy. That is new demand,
not cannibalized demand. It is also the most time-sensitive thing we sell, which
makes it the natural pairing with storm bookings ("dug out by 6am").

### Scope — the single most important decision in this document

We sell **dig out**, not **clean off**. Written this way everywhere it appears:

> We clear the snow around your vehicle — the plow berm, the wheel wells, and a
> path to the driver's door — and brush loose snow off the body and windows.
> We do not scrape ice, and nothing bladed or metal touches your vehicle.

**Why this sentence exists.** A shovel against a bumper, a brush across paint, a
snapped wiper, a cracked mirror. A $1,500 paint claim on a $40 job is
asymmetric, and over a season it will happen at least once. Providers are
independent contractors and insurance is only *required* today when they work
with a vehicle — a shovel-only provider may carry none. Narrowing the scope to
"snow around the car" removes most of the claim surface before it exists.

This sentence must appear in **three** places, not one:

1. The customer order screen, next to the option.
2. **The provider's job card**, every time. Not only the FAQ — the Provider
   Service Agreement is signed at registration only and existing providers are
   not re-gated, so a provider who signed v1.2 has never agreed to a vehicle
   scope clause. The job card is what actually binds them.
3. The Provider Service Agreement (bump `kProviderAgreementVersion` to 1.3 for
   people registering after this ships).

---

## 2. Data model

Mirror **deicer**, not the service selector. Deicer is already an orthogonal
add-on boolean and every layer of the app understands that shape. Making
vehicle a fourth `service_type` would explode the enum
(`sidewalk_driveway_vehicle`, `driveway_vehicle`, …) for no gain.

### Migration

```sql
-- jobs
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS vehicle boolean NOT NULL DEFAULT false;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS vehicle_count int NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS vehicle_description text;

-- storm_bookings (book-ahead must support it or the best use case is missing)
ALTER TABLE storm_bookings ADD COLUMN IF NOT EXISTS vehicle boolean NOT NULL DEFAULT false;
ALTER TABLE storm_bookings ADD COLUMN IF NOT EXISTS vehicle_count int NOT NULL DEFAULT 0;
ALTER TABLE storm_bookings ADD COLUMN IF NOT EXISTS vehicle_description text;

-- service_areas: per-zone pricing, like every other price here
ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS price_vehicle numeric;
ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS price_vehicle_addon numeric;
ALTER TABLE service_areas ADD COLUMN IF NOT EXISTS price_vehicle_extra numeric;

-- feature flag, so the customer option can be turned on independently of the
-- code that ships it (see rollout, §6)
INSERT INTO app_settings (key, value) VALUES ('vehicle_service_enabled', 'false')
ON CONFLICT (key) DO NOTHING;
```

`jobs.service_type` has **no CHECK constraint** (verified 2026-08-12), so the
value `'vehicle'` needs no schema change. `status` does have one — dig-out jobs
use the same five statuses, nothing new.

### service_type value

- Vehicle **added to** a snow order → `service_type` unchanged
  (`sidewalk` / `driveway` / `sidewalk_driveway`), `vehicle = true`.
- Vehicle **alone** → `service_type = 'vehicle'`, `driveway = false`,
  `walkway = false`, `vehicle = true`.

### Pricing

Three columns because the economics differ:

| Column | Meaning | Suggested Yonkers default |
|---|---|---|
| `price_vehicle` | vehicle-only order, first car | **$60** |
| `price_vehicle_addon` | first car when added to a snow order | **$40** |
| `price_vehicle_extra` | each additional car, either way | **$25** |

The standalone floor is higher than the add-on **on purpose**: drive time
dominates a 20-minute job. There is deliberately no distance cap in dispatch, so
a $40 standalone could be offered 15 miles out and lose the provider money. The
floor is what keeps it worth accepting.

⚠️ These are **starting numbers, not the source of truth.** Like every other
price here they are admin-editable per zone and will drift. Read the DB before
quoting them anywhere. Live Yonkers reference as of 2026-08-12: sidewalk $80 /
driveway $120 / both $160; deicer $45 / $70 / $90.

**Every reader must coalesce**, exactly like the deicer columns do:

```ts
const vehiclePrice = zone.price_vehicle ?? zone.price_driveway ?? 60
```

A zone row created before this migration has NULLs, and an uncoalesced read
prices the job at **$0**. That failure mode already happened once with the
per-surface deicer split; do not repeat it.

Storm surge and the per-address `price_multiplier` stack on top exactly as they
do today — no special-casing.

Cap `vehicle_count` at **3**. Beyond that it stops being a $25 marginal job and
becomes a parking lot.

### Vehicle description — required

Free text, required whenever `vehicle = true`: color, make, and where it's
parked. "Silver Honda Civic, in front of 34 Melrose, plate ABC-1234."

Without it a provider digs out the neighbor's car, which is a wasted job **and**
a stranger's damage claim. Prefill it from the most recent vehicle order at that
address (the same prefill mechanism already used for the order note), because
it's the same car nearly every time.

---

## 3. Compatibility — the part that breaks things

The server is shared by every app version already installed. When this ships,
providers will still be running build 22 and earlier. **Old customer builds are
safe** — they simply never offer the option. **Old provider and admin builds are
not**, because dispatch will hand them a job shape they have never seen.

### Hazard 1 — the job renders as the word "Service"

[`lib/utils/job_helpers.dart:8`](../lib/utils/job_helpers.dart#L8) builds the
job label from the booleans alone:

```dart
if (job['driveway'] == true) services.add('Driveway');
if (job['walkway'] == true) services.add('Sidewalk');
if (job['salting'] == true) services.add('Deicer');
return services.isEmpty ? 'Service' : services.join(' + ');
```

A vehicle-only job has all three false, so an old build shows a card titled
**"Service"** with no indication of what to do. It does not crash — it is worse
than a crash, because the provider accepts it and arrives not knowing the job.
This logic is compiled into every installed build and **cannot be fixed
server-side**. It is the reason for the dispatch gate in §3.5.

Fix in the new build: add `if (job['vehicle'] == true) services.add(...)` with
the count.

### Hazard 2 — storm bookings silently mislabel and misprice

[`supabase/functions/trigger-storm-bookings/index.ts:322`](../supabase/functions/trigger-storm-bookings/index.ts#L322):

```ts
walkway: b.service_type !== 'driveway',
driveway: b.service_type !== 'sidewalk',
```

`service_type = 'vehicle'` is neither, so **both become true** — the job is
written to the database as sidewalk + driveway. And the price ternary above it
(lines 219–224) ends in `: per(zone.price_sidewalk)`, so it charges the sidewalk
price. This is a live trap today, waiting for any fourth value.

Fix: make both explicit rather than negations, with a vehicle branch.

### Hazard 3 — checkout prices a vehicle-only order as a sidewalk

[`supabase/functions/create-checkout-session/index.ts:307`](../supabase/functions/create-checkout-session/index.ts#L307)
selects the price from `wantsWalkway` / `wantsDriveway`, falling through to
`price_sidewalk` when both are false. A vehicle-only order would be charged $80.

Fix: branch on the vehicle flag before the existing chain.

### Hazard 4 — two switches that default to "Sidewalk"

- [`lib/screens/admin/admin_screen.dart:5020`](../lib/screens/admin/admin_screen.dart#L5020) `_bookingService`
- [`lib/widgets/storm_booking_card.dart:310`](../lib/widgets/storm_booking_card.dart#L310) `_bookedService`

Both are `switch (b['service_type'])` with `_ => 'Sidewalk'`. A vehicle booking
displays as "Sidewalk" to the customer and the admin. Add a `'vehicle'` branch
to each.

### Hazard 5 — dispatch equipment ranking

No change required. The shovel penalty in `dispatch_jobs()` is conditional on
`driveway_size = 'large'`, which is NULL on a vehicle-only job, so the CASE is
false and nobody is penalized. Worth noting the opposite is true in reality — a
plow truck is useless against a street-parked car and a shovel is the right tool
— but ranking shovels *up* is an optimization, not a correctness fix. Leave it.

### 3.5 The gate — how we guarantee nothing breaks

Record the provider app build, and refuse to dispatch vehicle jobs to builds
that cannot render them.

```sql
ALTER TABLE providers ADD COLUMN IF NOT EXISTS app_build int;
```

Written when the provider **goes online** — which is already a fresh event every
session, because `is_online` is reset to false on every app open. No new
plumbing, and it self-heals the moment they update.

In `dispatch_jobs()`, add to both provider selects:

```sql
AND (NOT j.vehicle OR COALESCE(providers.app_build, 0) >= 23)
```

A vehicle job is then only ever offered to an app that understands it. Old
builds keep receiving normal jobs exactly as before, and nothing about their
behavior changes. This generalizes — every future service gets the same guard
for one line.

Watch the fleet before enabling:

```sql
SELECT COALESCE(app_build,0) AS build, count(*)
FROM providers WHERE registration_status='approved'
GROUP BY 1 ORDER BY 1;
```

---

## 4. App changes

### Customer — order screen ([`customer_home.dart`](../lib/screens/customer/customer_home.dart))

- Deicer-style add-on row: **"Dig out my car"**, price, and a 1–3 stepper.
- Required vehicle description field, shown only when the toggle is on.
- Scope sentence (§1) directly under it.
- Selecting *only* the vehicle add-on with no snow service is valid and prices
  at `price_vehicle` — the order button must not require a snow service.
- Gate the whole block on `AppConfig.vehicleServiceEnabled`.
- Storm-booking card: same add-on, since "dug out by 6am" is the best version
  of this product.

### Provider — ([`provider_home.dart`](../lib/screens/provider/provider_home.dart))

- Job card shows the vehicle chip, the count, and the **description**, plus the
  scope sentence.
- **Before photo becomes required** when `vehicle = true` (today it is optional
  and skippable). On a vehicle job the before shot is the entire defense against
  a pre-existing-damage claim, so it is not a nice-to-have. Keep the upload
  non-fatal for the *other* photos, but do not let Start proceed without this one.
- FAQ: how the service is scoped and what to do if the car is already damaged
  when they arrive (photograph it, note it, proceed).

### Admin — ([`admin_screen.dart`](../lib/screens/admin/admin_screen.dart))

- Areas tab: the three new price fields.
- Job cards: vehicle chip + description + count.
- The feature flag toggle, next to the storm-booking cap editor.

---

## 5. Sales tax — ask the CPA, do not guess

Snow removal is taxable in NY, which is why the Certificate of Authority work
exists. Whether clearing snow **off a vehicle** is taxed the same way is a
separate question — it is arguably a different service class — and it must go on
the list for whoever handles the CoA filing. `jobs.tax_amount` already exists
and flows from Stripe, so the plumbing is in place either way. Do not ship this
with a guessed tax treatment.

---

## 6. Rollout order

The order is the safety guarantee. Do not compress it.

1. **Migration.** Columns + flag (`false`). Completely inert.
2. **Harden the server readers** — hazards 2, 3 and the price coalescing —
   while zero vehicle jobs exist. Deploy.
3. **`app_build` + the dispatch gate.** Deploy. Still inert.
4. **Ship the app build** (call it 23) with customer, provider and admin
   rendering. Flag still `false`, so customers see nothing.
5. **Wait for the provider fleet.** Query above. Do not proceed on a hunch.
6. **Set prices per zone in the Areas tab.** A NULL price is a $0 job.
7. **Flip `vehicle_service_enabled` to true.** Customers can now order it.

Rollback at any point is flipping the flag back to `false`. Jobs already placed
keep working — nothing about the payment, capture, or refund path changes.

---

## 7. Test checklist

- [ ] Vehicle-only order prices at `price_vehicle`, **not** `price_sidewalk`
- [ ] Add-on to sidewalk+driveway prices at both + addon
- [ ] Second and third car add `price_vehicle_extra` each; 4th is refused
- [ ] Zone with NULL vehicle prices does not produce a $0 job
- [ ] Storm surge and per-address multiplier both stack correctly
- [ ] Shown price == charged price (`customer_home` vs `create-checkout-session`)
- [ ] Storm booking with vehicle triggers with the right price and label
- [ ] A build-22 provider is **never** offered a vehicle job
- [ ] A build-23 provider is, and the card shows the description
- [ ] Start blocks without a before photo on a vehicle job
- [ ] Receipt itemizes the vehicle line
- [ ] Admin job card, search, and payout math all include it
- [ ] Cancel before start releases the hold; after start refunds

---

## 8. Deliberately not doing

- **Ice scraping / de-icing the windshield.** Refused on purpose (§1). It is
  where the damage claims live and it needs equipment we do not require.
- **A fourth mutually-exclusive `service_type`.** Add-on boolean instead (§2).
- **Removing Sidewalk Only.** Considered and rejected 2026-08-12: Yonkers
  requires property owners to clear sidewalks within six hours of a daytime
  snowfall (noon the next day for overnight), a large share of the housing stock
  has no driveway, and collapsing to a bundle raises the most common order 33%.
