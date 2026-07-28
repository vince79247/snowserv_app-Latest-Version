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
}
