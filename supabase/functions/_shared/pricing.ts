// The order price math, server side — what the customer is actually CHARGED.
//
// Mirrors lib/utils/pricing.dart exactly, and both are verified against the
// same cases in test/pricing_cases.json (see pricing_test.ts next to this file
// and test/pricing_test.dart). This arithmetic used to be written out three
// separate times — the app, create-checkout-session, and
// trigger-storm-bookings — each carrying a comment asking the next reader to
// keep them in lockstep. A comment is not a test.
//
// Rounding: JS Math.round() rounds half toward +infinity and Dart's round()
// rounds half away from zero. Every price is positive, so they agree; the
// fixture includes exact .5 cases to keep it that way.

export type Zone = Record<string, unknown> | null

export interface OrderPrice {
  service: number
  salting: number
  base: number
  surge: number
  finalPrice: number
}

/** A zone price scaled by the per-address multiplier, rounded to whole dollars. */
export function perProperty(zonePrice: unknown, addressMultiplier: number): number {
  const n = Number(zonePrice)
  const base = Number.isFinite(n) ? n : 0
  return Math.round(base * addressMultiplier)
}

/** The snow-clearing price for the selected surfaces, before deicer and storm. */
export function servicePriceFor(
  zone: Zone, wantsWalkway: boolean, wantsDriveway: boolean, addressMultiplier = 1,
): number {
  if (!zone) return 0
  const key = wantsWalkway && wantsDriveway
    ? 'price_both'
    : wantsDriveway
      ? 'price_driveway'
      : 'price_sidewalk'
  return perProperty(zone[key], addressMultiplier)
}

/**
 * Deicer, priced PER SURFACE.
 *
 * price_salting keeps its original meaning (BOTH surfaces). The per-surface
 * columns coalesce back to it so a zone row saved before those columns existed
 * prices sanely instead of falling to $0 — which would hand out free deicer and
 * pay the provider 75% of a number that never included it.
 */
export function saltingPriceFor(
  zone: Zone, wantsWalkway: boolean, wantsDriveway: boolean, addressMultiplier = 1,
): number {
  if (!zone) return 0
  const key = wantsWalkway && wantsDriveway
    ? 'price_salting'
    : wantsDriveway
      ? 'price_salting_driveway'
      : 'price_salting_sidewalk'
  return perProperty(zone[key] ?? zone['price_salting'], addressMultiplier)
}

/** The whole calculation, in the order the customer experiences it. */
export function priceOrder(opts: {
  zone: Zone
  wantsWalkway: boolean
  wantsDriveway: boolean
  wantsSalting?: boolean
  addressMultiplier?: number
  surge?: number
}): OrderPrice {
  const mult = opts.addressMultiplier ?? 1
  const surge = opts.surge ?? 1
  const service = servicePriceFor(opts.zone, opts.wantsWalkway, opts.wantsDriveway, mult)
  const salting = opts.wantsSalting
    ? saltingPriceFor(opts.zone, opts.wantsWalkway, opts.wantsDriveway, mult)
    : 0
  const base = service + salting
  return {
    service,
    salting,
    base,
    surge,
    // Storm applies to the whole base, which already includes the per-address
    // multiplier — the two stack, they do not replace each other.
    finalPrice: Math.round(base * surge),
  }
}

/**
 * The three service_type values we persist, as surface booleans.
 *
 * Anything unrecognized bills as BOTH, matching the negation pair the storm
 * trigger has always used (walkway: type !== 'driveway'). That way a bad value
 * produces the most expensive reading — which someone notices — rather than a
 * silent $0 job.
 */
export function surfacesForServiceType(
  serviceType: string | null | undefined,
): { walkway: boolean; driveway: boolean } {
  if (serviceType === 'driveway') return { walkway: false, driveway: true }
  if (serviceType === 'sidewalk') return { walkway: true, driveway: false }
  return { walkway: true, driveway: true }
}
