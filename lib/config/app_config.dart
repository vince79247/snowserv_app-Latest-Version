import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One rung of the storm-pricing ladder: at [minInches] of snow on the ground
/// (and up to, but not including, [maxInches]) the job price is multiplied by
/// [multiplier]. [maxInches] null = the open-ended top band. This is the SINGLE
/// SOURCE OF TRUTH the customer price scale and the surge calc both read.
class StormBand {
  final int minInches; // inclusive lower bound
  final int? maxInches; // exclusive upper bound; null = open-ended top band
  final double multiplier;
  const StormBand(this.minInches, this.maxInches, this.multiplier);
  String get label =>
      maxInches == null ? '$minInches"+' : '$minInches–$maxInches"';
}

/// Editable business config loaded from the `app_settings` table so values like
/// the platform commission can be tuned from the admin panel — no code change.
/// Loaded once at startup (main) and after an admin edit.
class AppConfig {
  /// Platform commission as a percentage (e.g. 25 = 25%). Provider keeps the rest.
  /// This is only a fallback default — the live value is app_settings.commission_pct
  /// (currently 25), admin-editable from the panel; load() overwrites this at startup.
  static double commissionPct = 25;

  static double get platformFraction => commissionPct / 100.0;
  static double get providerFraction => (100.0 - commissionPct) / 100.0;

  /// Dispatch-offer window in SECONDS — how long a provider has to accept an
  /// offered job before it auto-declines and re-dispatches. SINGLE SOURCE OF
  /// TRUTH for both the provider UI countdown AND the pg_cron dispatch_jobs()
  /// expiry (they must agree or the countdown lies). Clamped 60–600s.
  static const int dispatchTimeoutMin = 60;
  static const int dispatchTimeoutMax = 600;
  static int dispatchTimeoutSeconds = 240;

  /// Storm-pricing ladder (snow depth -> price multiplier). Admin-editable via
  /// app_settings.storm_bands; the create-checkout-session function reads the
  /// SAME row, so the shown price always equals the charged price. This is only
  /// the fallback default (the Yonkers launch ladder) — load() overwrites it,
  /// and any invalid stored value keeps this default so pricing never breaks.
  static const List<StormBand> defaultStormBands = [
    StormBand(0, 3, 1.0),
    StormBand(3, 6, 1.3),
    StormBand(6, 10, 1.7),
    StormBand(10, null, 2.3),
  ];
  static List<StormBand> stormBands = defaultStormBands;

  static const double stormMultMin = 1.0; // storm pricing only ever raises price
  static const double stormMultMax = 5.0;

  /// Master switch for "Book my next storm" (app_settings.storm_booking_enabled).
  ///
  /// OFF for the launch season (decided with Vince 2026-08-13). Not because the
  /// feature is broken — it is built, and it was proven end to end against a
  /// real storm — but because it makes a PROMISE, and promises need supply
  /// behind them. Three providers can currently work. If fifteen people book
  /// ahead and a blizzard fires the cron at 4am, fifteen cards are charged and
  /// fifteen jobs appear for three people to cover, and those customers wake up
  /// to a debit and no service. On-demand fails gracefully by comparison — the
  /// customer watches it searching and can cancel with the hold released.
  ///
  /// Re-enable when the "Can work" count on the admin Providers tab comfortably
  /// exceeds the volume you would expect booked on a storm night. Flipping this
  /// to true is the entire re-launch: nothing was deleted.
  ///
  /// Default FALSE on purpose. A missing or unreadable setting must not switch
  /// on a feature that charges cards unattended.
  static bool stormBookingEnabled = false;

  /// Ceiling on storm pricing for a BOOKED-AHEAD job (app_settings
  /// .storm_booking_max_surge). A storm booking fires while the customer is
  /// asleep and authorizes their card off-session, so they cannot see the
  /// multiplier and decline it the way an on-demand customer can — this is the
  /// promise that replaces that missing consent: "book ahead and blizzard
  /// pricing never applies to you".
  ///
  /// 1.5 is close to free. On the launch ladder the bands are 1.0 / 1.2 / 1.5 /
  /// 2.0, so the cap only bites in the 10"+ band; every smaller storm already
  /// prices at or below it. Capping LOWER is not free: the provider takes their
  /// share of whatever is charged, so a hard 1.0x would make booked jobs pay
  /// half what the on-demand job next door pays, and providers reject what they
  /// can see is underpaid — the pre-booked jobs would be the ones nobody takes,
  /// during the worst storm of the year.
  ///
  /// Read by BOTH this app (to state the ceiling on the booking card) and the
  /// trigger-storm-bookings function (which enforces it), like storm_bands.
  static const double stormBookingCapMin = 1.0;
  static const double stormBookingCapMax = 5.0;
  static double stormBookingMaxSurge = 1.5;

  static Future<void> load() async {
    try {
      final rows = await Supabase.instance.client
          .from('app_settings')
          .select('key, value');
      final map = <String, String>{
        for (final r in rows)
          (r['key'] as String): (r['value']?.toString() ?? ''),
      };
      final c = double.tryParse(map['commission_pct'] ?? '');
      if (c != null && c >= 0 && c <= 100) commissionPct = c;
      final d = int.tryParse(map['dispatch_timeout_seconds'] ?? '');
      if (d != null && d >= dispatchTimeoutMin && d <= dispatchTimeoutMax) {
        dispatchTimeoutSeconds = d;
      }
      final sb = parseStormBands(map['storm_bands']);
      if (sb != null) stormBands = sb;
      final cap = double.tryParse(map['storm_booking_max_surge'] ?? '');
      if (cap != null && cap >= stormBookingCapMin && cap <= stormBookingCapMax) {
        stormBookingMaxSurge = cap;
      }
      // Only an explicit 'true' turns it on. Anything else — missing row,
      // typo, empty string — leaves it off, because the failure direction that
      // matters is "started charging cards nobody expected".
      stormBookingEnabled =
          (map['storm_booking_enabled'] ?? '').trim().toLowerCase() == 'true';
    } catch (_) {
      // Keep the defaults on any failure — pricing/dispatch must never break.
    }
  }

  /// Parse + validate the stored storm_bands JSON. Returns null (→ keep the
  /// default) if anything is off, so a bad value can never corrupt pricing.
  /// Rules: non-empty array of {min, mult}; min>=0; mult in [stormMultMin,
  /// stormMultMax]; strictly ascending by min; first band starts at 0". The
  /// exclusive upper bound of each band is the next band's min (top = open).
  static List<StormBand>? parseStormBands(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;
      final mins = <int>[];
      final mults = <double>[];
      for (final item in decoded) {
        if (item is! Map) return null;
        final min = (item['min'] as num?)?.toInt();
        final mult = (item['mult'] as num?)?.toDouble();
        if (min == null || mult == null) return null;
        if (min < 0 || mult < stormMultMin || mult > stormMultMax) return null;
        mins.add(min);
        mults.add(mult);
      }
      if (mins.first != 0) return null;
      for (int i = 1; i < mins.length; i++) {
        if (mins[i] <= mins[i - 1]) return null; // must strictly ascend
      }
      return [
        for (int i = 0; i < mins.length; i++)
          StormBand(mins[i], i < mins.length - 1 ? mins[i + 1] : null, mults[i]),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Admin: persist a new commission % and update the in-memory value.
  static Future<void> setCommissionPct(double pct) async {
    final clamped = pct.clamp(0, 100).toDouble();
    await Supabase.instance.client.from('app_settings').update({
      'value': clamped.toStringAsFixed(clamped == clamped.roundToDouble() ? 0 : 2),
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('key', 'commission_pct');
    commissionPct = clamped;
  }

  /// Admin: persist a new dispatch-offer window (seconds) and update the
  /// in-memory value. The pg_cron dispatch_jobs() reads the same setting, so the
  /// server expiry and the provider countdown stay in lockstep.
  static Future<void> setDispatchTimeoutSeconds(int seconds) async {
    final clamped = seconds.clamp(dispatchTimeoutMin, dispatchTimeoutMax);
    await Supabase.instance.client.from('app_settings').update({
      'value': clamped.toString(),
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('key', 'dispatch_timeout_seconds');
    dispatchTimeoutSeconds = clamped;
  }

  /// Admin: persist a new storm-pricing ladder and update the in-memory value.
  /// The create-checkout-session function reads the same app_settings row, so
  /// the customer price scale and the actual charge stay in lockstep. Upsert
  /// (not update) so it self-heals if the seed row is ever missing.
  static Future<void> setStormBands(List<StormBand> bands) async {
    final payload = jsonEncode([
      for (final b in bands) {'min': b.minInches, 'mult': b.multiplier},
    ]);
    await Supabase.instance.client.from('app_settings').upsert({
      'key': 'storm_bands',
      'value': payload,
      'updated_at': DateTime.now().toIso8601String(),
    });
    stormBands = bands;
  }

  /// Admin: persist the storm-booking price ceiling. trigger-storm-bookings
  /// reads the SAME app_settings row and enforces it, so the cap promised on
  /// the booking card is the cap actually charged. Upsert (not update) so it
  /// self-heals if the seed row is ever missing.
  static Future<void> setStormBookingMaxSurge(double cap) async {
    final clamped = cap.clamp(stormBookingCapMin, stormBookingCapMax);
    await Supabase.instance.client.from('app_settings').upsert({
      'key': 'storm_booking_max_surge',
      'value': clamped.toString(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    stormBookingMaxSurge = clamped;
  }

  /// Turn "Book my next storm" on or off. The server checks the same row before
  /// firing anything, so this is not merely hiding the card.
  static Future<void> setStormBookingEnabled(bool enabled) async {
    await Supabase.instance.client.from('app_settings').upsert({
      'key': 'storm_booking_enabled',
      'value': enabled.toString(),
      'updated_at': DateTime.now().toIso8601String(),
    });
    stormBookingEnabled = enabled;
  }
}
