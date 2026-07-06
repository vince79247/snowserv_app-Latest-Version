// Geofence matching for pricing zones.
//
// Zones live in the `service_areas` table. Each zone can carry a `polygon`
// (jsonb: an ordered list of {lat,lng} vertices) that defines its boundary.
// A customer's geocoded address (lat/lng) is tested against those polygons to
// decide which zone — and therefore which prices — applies.
//
// Matching is done client-side (there are only a handful of active zones), so
// no PostGIS/RPC is needed. For zones that don't have a polygon drawn yet, we
// fall back to the legacy ZIP list so nothing breaks during the migration.

/// A single polygon vertex as {'lat': double, 'lng': double}.
typedef LatLngPoint = Map<String, double>;

/// Parse the `polygon` column (jsonb) into a list of {lat,lng} vertices.
/// Tolerates null, an empty list, or malformed entries (skipped). Returns an
/// empty list when there is no usable polygon.
List<LatLngPoint> parsePolygon(dynamic raw) {
  if (raw is! List) return const [];
  final out = <LatLngPoint>[];
  for (final v in raw) {
    if (v is Map) {
      final lat = (v['lat'] as num?)?.toDouble();
      final lng = (v['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) out.add({'lat': lat, 'lng': lng});
    }
  }
  return out;
}

/// Ray-casting point-in-polygon test. `polygon` is an ordered list of
/// {lat,lng} vertices (open or closed ring — both work). Returns false for a
/// degenerate polygon (< 3 vertices).
bool pointInPolygon(double lat, double lng, List<LatLngPoint> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final yi = polygon[i]['lat']!, xi = polygon[i]['lng']!;
    final yj = polygon[j]['lat']!, xj = polygon[j]['lng']!;
    final intersects = ((yi > lat) != (yj > lat)) &&
        (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi);
    if (intersects) inside = !inside;
  }
  return inside;
}

/// Pick the pricing zone for a geocoded point among the given active zones.
///
/// Preference order per zone:
///   1. `polygon` contains the point (the geofence), else
///   2. legacy fallback: `zip` is listed in the zone's `zips` array.
///
/// Returns the matched zone map (with its `price_*` fields) or null if none
/// match. `lat`/`lng` may be null (geocode failed) — then only the ZIP
/// fallback can match.
Map<String, dynamic>? matchZone(
  double? lat,
  double? lng, {
  String? zip,
  required List<Map<String, dynamic>> zones,
}) {
  for (final zone in zones) {
    final poly = parsePolygon(zone['polygon']);
    // When the zone has a real geofence AND we have a geocoded point, the
    // boundary is authoritative — inside matches, outside is skipped (don't let
    // stale ZIPs override the drawn boundary).
    if (poly.isNotEmpty && lat != null && lng != null) {
      if (pointInPolygon(lat, lng, poly)) return zone;
      continue;
    }
    // No polygon drawn yet, or geocoding failed (no point) → legacy ZIP match.
    if (zip != null && zip.isNotEmpty) {
      final zips = (zone['zips'] as List?)?.map((z) => z.toString()).toList() ?? const [];
      if (zips.contains(zip)) return zone;
    }
  }
  return null;
}
