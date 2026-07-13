import 'package:supabase_flutter/supabase_flutter.dart';

/// Editable business config loaded from the `app_settings` table so values like
/// the platform commission can be tuned from the admin panel — no code change.
/// Loaded once at startup (main) and after an admin edit.
class AppConfig {
  /// Platform commission as a percentage (e.g. 30 = 30%). Provider keeps the rest.
  static double commissionPct = 30;

  static double get platformFraction => commissionPct / 100.0;
  static double get providerFraction => (100.0 - commissionPct) / 100.0;

  /// Dispatch-offer window in SECONDS — how long a provider has to accept an
  /// offered job before it auto-declines and re-dispatches. SINGLE SOURCE OF
  /// TRUTH for both the provider UI countdown AND the pg_cron dispatch_jobs()
  /// expiry (they must agree or the countdown lies). Clamped 60–600s.
  static const int dispatchTimeoutMin = 60;
  static const int dispatchTimeoutMax = 600;
  static int dispatchTimeoutSeconds = 240;

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
    } catch (_) {
      // Keep the defaults on any failure — pricing/dispatch must never break.
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
}
