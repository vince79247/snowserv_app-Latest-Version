// Shared job-related helpers used across customer, provider, and admin screens.
// Consolidated here so the same logic isn't copy-pasted (and allowed to drift)
// across multiple files.

/// Human-readable service description, e.g. "Driveway + Sidewalk + Salting".
String describeJob(Map<String, dynamic> job) {
  final List<String> services = [];
  if (job['driveway'] == true) services.add('Driveway');
  if (job['walkway'] == true) services.add('Sidewalk');
  if (job['salting'] == true) services.add('Salting');
  return services.isEmpty ? 'Service' : services.join(' + ');
}

/// Short M/D/YYYY date from an ISO timestamp string, in local time.
String formatDate(String dateStr) {
  final date = DateTime.parse(dateStr).toLocal();
  return '${date.month}/${date.day}/${date.year}';
}

/// Provider's take-home pay (70% of the job total), rounded to whole dollars.
int providerPay(Map<String, dynamic> job) {
  final total = (job['final_price'] ?? job['base_price'] ?? 0) as num;
  return (total * 0.70).round();
}

/// Cheap squared-distance approximation for ranking providers by proximity.
/// The 0.7 factor roughly corrects longitude for US latitudes. Not a true
/// distance — only valid for comparing/sorting, never for display.
double dist2(double lat1, double lng1, double lat2, double lng2) {
  final dlat = lat2 - lat1;
  final dlng = (lng2 - lng1) * 0.7;
  return dlat * dlat + dlng * dlng;
}
