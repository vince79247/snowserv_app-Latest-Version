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

/// Unsigned area of a polygon ring via the shoelace formula, in squared-degree
/// units. Only used to COMPARE overlapping zones (smaller = more specific), so
/// the unit is irrelevant as long as it's consistent — overlapping zones sit in
/// the same area, so any longitude distortion cancels out of the comparison.
/// Returns 0 for a degenerate ring (< 3 vertices).
double polygonArea(List<LatLngPoint> polygon) {
  if (polygon.length < 3) return 0;
  var sum = 0.0;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final xi = polygon[i]['lng']!, yi = polygon[i]['lat']!;
    final xj = polygon[j]['lng']!, yj = polygon[j]['lat']!;
    sum += (xj * yi) - (xi * yj);
  }
  return sum.abs() / 2.0;
}

/// Pick the pricing zone for a geocoded point among the given active zones.
///
/// Preference order:
///   1. Geofence — among every zone whose `polygon` contains the point, the
///      SMALLEST-area one wins. This lets a premium "pocket" drawn on top of a
///      larger zone take precedence (most-specific match), and makes the result
///      independent of the order the zones happen to be fetched in.
///   2. Legacy fallback: `zip` is listed in the zone's `zips` array — used only
///      for zones with no polygon drawn yet, or when geocoding failed (no point).
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
  // 1. Geofence: smallest containing polygon wins (most specific).
  if (lat != null && lng != null) {
    Map<String, dynamic>? best;
    var bestArea = double.infinity;
    for (final zone in zones) {
      final poly = parsePolygon(zone['polygon']);
      if (poly.isEmpty || !pointInPolygon(lat, lng, poly)) continue;
      final area = polygonArea(poly);
      if (area < bestArea) {
        bestArea = area;
        best = zone;
      }
    }
    if (best != null) return best;
  }
  // 2. Legacy ZIP fallback. A drawn boundary is authoritative, so when we have a
  // point, a zone WITH a polygon that didn't contain it is a real "no" — only
  // polygon-less zones (or a failed geocode) fall back to ZIP.
  if (zip != null && zip.isNotEmpty) {
    for (final zone in zones) {
      final hasPolygon = parsePolygon(zone['polygon']).isNotEmpty;
      if (lat != null && lng != null && hasPolygon) continue;
      final zips = (zone['zips'] as List?)?.map((z) => z.toString()).toList() ?? const [];
      if (zips.contains(zip)) return zone;
    }
  }
  return null;
}
