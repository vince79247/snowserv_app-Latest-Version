import 'dart:convert';
import 'package:http/http.dart' as http;

// Address → lat/lng geocoding.
//
// PRIMARY: the US Census Bureau geocoder (free, no API key, and — unlike
// Nominatim — it explicitly permits server/datacenter use). That matters because
// the SERVER (create-checkout-session) has to geocode the same address to price
// the order, and Nominatim blocks datacenter IPs: it failed there every time,
// which silently zeroed storm surge and left job_lat null (2026-07-29).
// FALLBACK: Nominatim, for anything the Census can't match (it's US-only and
// wants a real street address).
//
// Keep this chain IDENTICAL to the port in supabase/functions/
// create-checkout-session/index.ts — if the two sides resolve an address
// differently they can land in different pricing zones near a boundary, and the
// shown price would stop matching the charged price.

/// Geocode an address map ({address_line, city, state, zip}) to
/// {'lat': double, 'lng': double}. Returns null on failure/no match.
Future<Map<String, double>?> geocodeAddress(Map<String, dynamic> address) async {
  final oneLine =
      '${address['address_line']}, ${address['city']}, ${address['state']} ${address['zip']}';
  return await _census(oneLine) ?? await _nominatim(oneLine);
}

/// US Census Bureau geocoder — free, keyless, server-use OK, US addresses only.
Future<Map<String, double>?> _census(String oneLine) async {
  try {
    final res = await http.get(
      Uri.parse('https://geocoding.geo.census.gov/geocoder/locations/onelineaddress'
          '?address=${Uri.encodeComponent(oneLine)}'
          '&benchmark=Public_AR_Current&format=json'),
    ).timeout(const Duration(seconds: 6));
    if (res.statusCode == 200) {
      final matches =
          jsonDecode(res.body)?['result']?['addressMatches'] as List?;
      if (matches != null && matches.isNotEmpty) {
        final c = matches[0]['coordinates'];
        final lat = (c?['y'] as num?)?.toDouble();
        final lng = (c?['x'] as num?)?.toDouble();
        if (lat != null && lng != null) return {'lat': lat, 'lng': lng};
      }
    }
  } catch (_) {}
  return null;
}

/// OpenStreetMap Nominatim — fallback only (rate-limited ~1 req/s; blocks
/// datacenter IPs, so it can't be the primary for the server-side port).
Future<Map<String, double>?> _nominatim(String oneLine) async {
  try {
    final res = await http.get(
      Uri.parse('https://nominatim.openstreetmap.org/search'
          '?q=${Uri.encodeComponent(oneLine)}&format=json&limit=1'),
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
