import 'dart:convert';
import 'package:http/http.dart' as http;

// Address → lat/lng geocoding via OpenStreetMap Nominatim (free, no API key).
//
// NOTE: Nominatim is rate-limited (~1 req/s) and not intended for heavy
// commercial volume. Callers should debounce and reuse the result. For scale,
// swap this for a paid geocoder (Google/Mapbox) — see PRELAUNCH.md.

/// Geocode an address map ({address_line, city, state, zip}) to
/// {'lat': double, 'lng': double}. Returns null on failure/no match.
Future<Map<String, double>?> geocodeAddress(Map<String, dynamic> address) async {
  try {
    final query = Uri.encodeComponent(
        '${address['address_line']}, ${address['city']}, ${address['state']} ${address['zip']}');
    final res = await http.get(
      Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&limit=1'),
      headers: {'User-Agent': 'SnowServApp/1.0'},
    ).timeout(const Duration(seconds: 5));
    if (res.statusCode == 200) {
      final results = jsonDecode(res.body) as List;
      if (results.isNotEmpty) {
        return {
          'lat': double.parse(results[0]['lat']),
          'lng': double.parse(results[0]['lon']),
        };
      }
    }
  } catch (_) {}
  return null;
}
