// Shared job-related helpers used across customer, provider, and admin screens.
// Consolidated here so the same logic isn't copy-pasted (and allowed to drift)
// across multiple files.

import '../config/app_config.dart';

/// Human-readable service description, e.g. "Driveway + Sidewalk + Deicer".
String describeJob(Map<String, dynamic> job) {
  final List<String> services = [];
  if (job['driveway'] == true) services.add('Driveway');
  if (job['walkway'] == true) services.add('Sidewalk');
  if (job['salting'] == true) services.add('Deicer');
  return services.isEmpty ? 'Service' : services.join(' + ');
}

/// Short M/D/YYYY date from an ISO timestamp string, in local time.
String formatDate(String dateStr) {
  final date = DateTime.parse(dateStr).toLocal();
  return '${date.month}/${date.day}/${date.year}';
}

/// Date + 12-hour time in local time, e.g. "7/11 8:03 AM". Null-safe: returns
/// "—" when the timestamp is missing (that lifecycle step hasn't happened yet).
String formatDateTime(dynamic ts) {
  if (ts == null) return '—';
  final d = DateTime.tryParse(ts.toString())?.toLocal();
  if (d == null) return '—';
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${d.month}/${d.day} $h12:${d.minute.toString().padLeft(2, '0')} $ampm';
}

/// Human span between two ISO timestamps, e.g. "31 min" or "1h 12m". Returns ''
/// if either is missing or the span is negative.
String durationBetween(dynamic start, dynamic end) {
  if (start == null || end == null) return '';
  final s = DateTime.tryParse(start.toString());
  final e = DateTime.tryParse(end.toString());
  if (s == null || e == null) return '';
  final mins = e.difference(s).inMinutes;
  if (mins < 0) return '';
  return mins < 60 ? '$mins min' : '${mins ~/ 60}h ${mins % 60}m';
}

/// Provider's take-home pay (the provider's share of the job total, per the
/// admin-configured commission), rounded to whole dollars.
int providerPay(Map<String, dynamic> job) {
  final total = (job['final_price'] ?? job['base_price'] ?? 0) as num;
  return (total * AppConfig.providerFraction).round();
}

/// Cheap squared-distance approximation for ranking providers by proximity.
/// The 0.7 factor roughly corrects longitude for US latitudes. Not a true
/// distance — only valid for comparing/sorting, never for display.
double dist2(double lat1, double lng1, double lat2, double lng2) {
  final dlat = lat2 - lat1;
  final dlng = (lng2 - lng1) * 0.7;
  return dlat * dlat + dlng * dlng;
}
