// The order price math, in one place.
//
// WHY THIS FILE EXISTS: this arithmetic was written out three times — here in
// the app (what the customer is SHOWN), in create-checkout-session (what they
// are CHARGED), and again in trigger-storm-bookings (what a booked-ahead job
// charges). All three carried comments telling the next reader to keep them
// "in lockstep", which is a code comment doing a test's job. Drift between the
// shown and charged number is the single worst bug this app can have: the
// customer sees $160, the card is debited something else, and nothing in the
// app disagrees with itself loudly enough to notice.
//
// The Dart and TypeScript versions are verified against the SAME cases in
// test/pricing_cases.json — see test/pricing_test.dart and
// supabase/functions/_shared/pricing_test.ts. Change the math in one language
// and the other language's test suite fails.
//
// Rounding note: Dart's num.round() rounds half AWAY FROM ZERO and JavaScript's
// Math.round() rounds half toward +infinity. Every price here is positive, so
// the two agree; pricing_cases.json includes exact .5 cases to keep that true.

/// A zone price scaled by the per-address multiplier, rounded to whole dollars.
///
/// Null/absent prices collapse to 0 rather than throwing — an unserved address
/// has no zone, and the UI renders $0 while the order button is disabled.
int perProperty(dynamic zonePrice, double addressMultiplier) =>
    (((zonePrice as num?)?.toDouble() ?? 0) * addressMultiplier).round();

/// The snow-clearing price for the selected surfaces, before deicer and storm.
int servicePriceFor({
  required Map<String, dynamic>? zone,
  required bool wantsWalkway,
  required bool wantsDriveway,
  double addressMultiplier = 1.0,
}) {
  if (zone == null) return 0;
  final key = wantsWalkway && wantsDriveway
      ? 'price_both'
      : wantsDriveway
          ? 'price_driveway'
          : 'price_sidewalk';
  return perProperty(zone[key], addressMultiplier);
}

/// Deicer, priced PER SURFACE.
///
/// Salting a sidewalk uses less salt and less time than salting a sidewalk and
/// a driveway, and one flat fee made a sidewalk-only order cost more to salt
/// ($90) than to shovel ($80).
///
/// price_salting keeps its original meaning (BOTH surfaces). The per-surface
/// columns coalesce back to it so a zone row saved before those columns existed
/// prices sanely instead of falling to $0.
int saltingPriceFor({
  required Map<String, dynamic>? zone,
  required bool wantsWalkway,
  required bool wantsDriveway,
  double addressMultiplier = 1.0,
}) {
  if (zone == null) return 0;
  final key = wantsWalkway && wantsDriveway
      ? 'price_salting'
      : wantsDriveway
          ? 'price_salting_driveway'
          : 'price_salting_sidewalk';
  return perProperty(zone[key] ?? zone['price_salting'], addressMultiplier);
}

/// Everything about what an order costs. `base` is what the services come to
/// with the per-address multiplier already applied; `finalPrice` adds storm.
class OrderPrice {
  final int service;
  final int salting;
  final int base;
  final double surge;
  final int finalPrice;
  const OrderPrice({
    required this.service,
    required this.salting,
    required this.base,
    required this.surge,
    required this.finalPrice,
  });
}

/// The whole calculation, in the order the customer experiences it.
OrderPrice priceOrder({
  required Map<String, dynamic>? zone,
  required bool wantsWalkway,
  required bool wantsDriveway,
  bool wantsSalting = false,
  double addressMultiplier = 1.0,
  double surge = 1.0,
}) {
  final service = servicePriceFor(
    zone: zone,
    wantsWalkway: wantsWalkway,
    wantsDriveway: wantsDriveway,
    addressMultiplier: addressMultiplier,
  );
  final salt = wantsSalting
      ? saltingPriceFor(
          zone: zone,
          wantsWalkway: wantsWalkway,
          wantsDriveway: wantsDriveway,
          addressMultiplier: addressMultiplier,
        )
      : 0;
  final base = service + salt;
  return OrderPrice(
    service: service,
    salting: salt,
    base: base,
    surge: surge,
    // Storm applies to the whole base, which already includes the per-address
    // multiplier — the two stack, they do not replace each other.
    finalPrice: (base * surge).round(),
  );
}

/// The three service_type values the app stores, as surface booleans.
/// storm_bookings and jobs both persist service_type, so this is the bridge
/// between a stored booking and the surface-based math above.
({bool walkway, bool driveway}) surfacesForServiceType(String? serviceType) =>
    switch (serviceType) {
      'driveway' => (walkway: false, driveway: true),
      'sidewalk' => (walkway: true, driveway: false),
      // 'sidewalk_driveway' and anything unrecognized bill as both, matching
      // the server's `type !== 'driveway'` / `type !== 'sidewalk'` pair.
      _ => (walkway: true, driveway: true),
    };
