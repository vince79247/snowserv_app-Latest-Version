import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme.dart';
import '../../utils/geo.dart';

// Admin "Live Map": shows where the online drivers are, laid over the service
// zone boundaries — so the admin can eyeball coverage and decide to send a
// driver into a neighbouring zone. Read-only view; data is whatever the admin
// panel already loaded (providers + service_areas + jobs), passed in so this
// screen never re-queries.
class AdminMapScreen extends StatefulWidget {
  final List<Map<String, dynamic>> providers;
  final List<Map<String, dynamic>> serviceAreas;
  final List<Map<String, dynamic>> jobs;
  const AdminMapScreen({
    super.key,
    required this.providers,
    required this.serviceAreas,
    required this.jobs,
  });

  @override
  State<AdminMapScreen> createState() => _AdminMapScreenState();
}

class _AdminMapScreenState extends State<AdminMapScreen> {
  final _mapController = MapController();
  bool _showOffline = false;

  // Yonkers, NY — same default center the zone editor uses.
  static const _defaultCenter = LatLng(40.9312, -73.8988);

  // A palette so each zone reads as a distinct region on the map.
  static const _zoneColors = [
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFF6A1B9A),
    Color(0xFFC62828),
    Color(0xFFEF6C00),
    Color(0xFF00838F),
  ];

  // Providers with a known GPS fix — the only ones we can pin.
  List<Map<String, dynamic>> get _located => widget.providers.where((p) {
        final lat = (p['current_lat'] as num?)?.toDouble();
        final lng = (p['current_lng'] as num?)?.toDouble();
        if (lat == null || lng == null) return false;
        if (p['is_online'] == true) return true;
        return _showOffline; // offline drivers only when the toggle is on
      }).toList();

  int _onlineCount() =>
      widget.providers.where((p) => p['is_online'] == true).length;

  int _activeJobs(String? providerId) {
    if (providerId == null) return 0;
    return widget.jobs
        .where((j) =>
            j['provider_id']?.toString() == providerId &&
            (j['status'] == 'assigned' || j['status'] == 'in_progress'))
        .length;
  }

  String _initialOf(String? name) {
    final t = (name ?? '').trim();
    return t.isEmpty ? '?' : t[0].toUpperCase();
  }

  bool _isPreferred(Map<String, dynamic> p) {
    final raw = p['preferred_until'];
    if (raw == null) return false;
    final until = DateTime.tryParse(raw.toString());
    return until != null && until.isAfter(DateTime.now());
  }

  // Centroid of a polygon's vertices — used to place the zone's name label.
  LatLng? _centroid(List<LatLngPoint> pts) {
    if (pts.isEmpty) return null;
    var lat = 0.0, lng = 0.0;
    for (final v in pts) {
      lat += v['lat']!;
      lng += v['lng']!;
    }
    return LatLng(lat / pts.length, lng / pts.length);
  }

  // Which active zone (by name) a point currently sits inside, if any.
  String? _zoneNameFor(double lat, double lng) {
    final zone = matchZone(lat, lng, zones: widget.serviceAreas);
    return zone?['name']?.toString();
  }

  LatLng get _initialCenter {
    // Prefer the average of located drivers; else the first zone; else default.
    final loc = _located;
    if (loc.isNotEmpty) {
      var lat = 0.0, lng = 0.0;
      for (final p in loc) {
        lat += (p['current_lat'] as num).toDouble();
        lng += (p['current_lng'] as num).toDouble();
      }
      return LatLng(lat / loc.length, lng / loc.length);
    }
    for (final z in widget.serviceAreas) {
      final c = _centroid(parsePolygon(z['polygon']));
      if (c != null) return c;
    }
    return _defaultCenter;
  }

  Future<void> _dial(String scheme, String phone) async {
    final uri = Uri(scheme: scheme, path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _openDriver(Map<String, dynamic> p) {
    final name = p['users']?['name']?.toString() ?? 'Driver';
    final phone = p['users']?['phone']?.toString();
    final online = p['is_online'] == true;
    final lat = (p['current_lat'] as num?)?.toDouble();
    final lng = (p['current_lng'] as num?)?.toDouble();
    final zoneName = (lat != null && lng != null) ? _zoneNameFor(lat, lng) : null;
    final active = _activeJobs(p['id']?.toString());
    final preferred = _isPreferred(p);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: online ? Colors.green : Colors.grey,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(name,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
              if (preferred)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3CD),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('★ Preferred',
                      style: TextStyle(
                          color: Color(0xFF8A6D00),
                          fontWeight: FontWeight.bold,
                          fontSize: 12)),
                ),
            ]),
            const SizedBox(height: 6),
            Text(
              '${online ? 'Online' : 'Offline'}  ·  $active active job${active == 1 ? '' : 's'}'
              '${zoneName != null ? '  ·  in $zoneName' : '  ·  outside any zone'}',
              style: TextStyle(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 16),
            if (phone != null && phone.isNotEmpty)
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _dial('tel', phone),
                    icon: const Icon(Icons.call),
                    label: const Text('Call'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _dial('sms', phone),
                    icon: const Icon(Icons.sms),
                    label: const Text('Text'),
                  ),
                ),
              ])
            else
              Text('No phone number on file.',
                  style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final located = _located;
    final zones = widget.serviceAreas
        .where((z) => z['is_active'] == true)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Map'),
        actions: [
          Row(children: [
            const Text('Offline', style: TextStyle(fontSize: 13)),
            Switch(
              value: _showOffline,
              onChanged: (v) => setState(() => _showOffline = v),
            ),
          ]),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _initialCenter,
                    initialZoom: 12,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.snowserv.app',
                    ),
                    // Zone boundaries, each a distinct color.
                    PolygonLayer(polygons: [
                      for (var i = 0; i < zones.length; i++)
                        if (parsePolygon(zones[i]['polygon']).length >= 3)
                          Polygon(
                            points: parsePolygon(zones[i]['polygon'])
                                .map((v) => LatLng(v['lat']!, v['lng']!))
                                .toList(),
                            color: _zoneColors[i % _zoneColors.length]
                                .withOpacity(0.12),
                            borderColor: _zoneColors[i % _zoneColors.length],
                            borderStrokeWidth: 2,
                          ),
                    ]),
                    // Zone name labels at each polygon centroid.
                    MarkerLayer(markers: [
                      for (var i = 0; i < zones.length; i++)
                        if (_centroid(parsePolygon(zones[i]['polygon'])) != null)
                          Marker(
                            point: _centroid(parsePolygon(zones[i]['polygon']))!,
                            width: 120,
                            height: 24,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.85),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                zones[i]['name']?.toString() ?? '',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: _zoneColors[i % _zoneColors.length],
                                ),
                              ),
                            ),
                          ),
                    ]),
                    // Driver pins.
                    MarkerLayer(markers: [
                      for (final p in located)
                        Marker(
                          point: LatLng(
                            (p['current_lat'] as num).toDouble(),
                            (p['current_lng'] as num).toDouble(),
                          ),
                          width: 44,
                          height: 54,
                          child: GestureDetector(
                            onTap: () => _openDriver(p),
                            child: _DriverPin(
                              online: p['is_online'] == true,
                              preferred: _isPreferred(p),
                              initial: _initialOf(p['users']?['name']?.toString()),
                            ),
                          ),
                        ),
                    ]),
                  ],
                ),
                if (zones.isEmpty && located.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No zones drawn and no drivers located yet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Summary strip.
          Container(
            color: SnowServColors.navy,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('${_onlineCount()}', 'Online'),
                _stat('${located.length}', 'On map'),
                _stat('${zones.length}', 'Zones'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      );
}

// A teardrop map pin bearing the driver's initial. Green = online,
// grey = offline; a gold ring marks a preferred driver.
class _DriverPin extends StatelessWidget {
  final bool online;
  final bool preferred;
  final String initial;
  const _DriverPin({
    required this.online,
    required this.preferred,
    required this.initial,
  });

  @override
  Widget build(BuildContext context) {
    final base = online ? Colors.green.shade600 : Colors.grey.shade600;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: base,
            shape: BoxShape.circle,
            border: Border.all(
              color: preferred ? const Color(0xFFFFC107) : Colors.white,
              width: 3,
            ),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 3),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        // little pointer under the circle
        Transform.translate(
          offset: const Offset(0, -4),
          child: Icon(Icons.arrow_drop_down, color: base, size: 20),
        ),
      ],
    );
  }
}
