import 'package:supabase_flutter/supabase_flutter.dart';

/// Editable business config loaded from the `app_settings` table so values like
/// the platform commission can be tuned from the admin panel — no code change.
/// Loaded once at startup (main) and after an admin edit.
class AppConfig {
  /// Platform commission as a percentage (e.g. 30 = 30%). Provider keeps the rest.
  static double commissionPct = 30;

  static double get platformFraction => commissionPct / 100.0;
  static double get providerFraction => (100.0 - commissionPct) / 100.0;

  static Future<void> load() async {
    try {
      final row = await Supabase.instance.client
          .from('app_settings')
          .select('value')
          .eq('key', 'commission_pct')
          .maybeSingle();
      final v = double.tryParse(row?['value']?.toString() ?? '');
      if (v != null && v >= 0 && v <= 100) commissionPct = v;
    } catch (_) {
      // Keep the default on any failure — pricing must never break.
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
}
