import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';
import '../../utils/geo.dart';
import '../../utils/geocode.dart';

final _supabase = Supabase.instance.client;

// Full-screen editor for a pricing zone (row in `service_areas`). The service
// boundary is drawn as a polygon on a map: tap to drop corner points, and the
// enclosed area becomes the geofence. Prices + name are edited alongside.
class ZoneEditorScreen extends StatefulWidget {
  final Map<String, dynamic>? zone; // null = creating a new zone
  const ZoneEditorScreen({super.key, this.zone});

  @override
  State<ZoneEditorScreen> createState() => _ZoneEditorScreenState();
}

class _ZoneEditorScreenState extends State<ZoneEditorScreen> {
  final _mapController = MapController();
  final _nameCtrl = TextEditingController();
  final _sidewalkCtrl = TextEditingController(text: '50');
  final _drivewayCtrl = TextEditingController(text: '100');
  final _bothCtrl = TextEditingController(text: '125');
  final _saltingCtrl = TextEditingController(text: '40');
  final _searchCtrl = TextEditingController();

  final List<LatLng> _points = [];
  bool _saving = false;
  bool _searching = false;

  // Yonkers, NY — a sensible default center for a fresh zone.
  static const _defaultCenter = LatLng(40.9312, -73.8988);

  @override
  void initState() {
    super.initState();
    final z = widget.zone;
    if (z != null) {
      _nameCtrl.text = z['name']?.toString() ?? '';
      _sidewalkCtrl.text = z['price_sidewalk']?.toString() ?? '50';
      _drivewayCtrl.text = z['price_driveway']?.toString() ?? '100';
      _bothCtrl.text = z['price_both']?.toString() ?? '125';
      _saltingCtrl.text = z['price_salting']?.toString() ?? '40';
      for (final v in parsePolygon(z['polygon'])) {
        _points.add(LatLng(v['lat']!, v['lng']!));
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sidewalkCtrl.dispose();
    _drivewayCtrl.dispose();
    _bothCtrl.dispose();
    _saltingCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  LatLng get _initialCenter {
    if (_points.isEmpty) return _defaultCenter;
    var lat = 0.0, lng = 0.0;
    for (final p in _points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / _points.length, lng / _points.length);
  }

  Future<void> _searchAddress() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    final geo = await geocodeAddress({'address_line': q, 'city': '', 'state': '', 'zip': ''});
    if (!mounted) return;
    setState(() => _searching = false);
    if (geo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't find that address.")),
      );
      return;
    }
    _mapController.move(LatLng(geo['lat']!, geo['lng']!), 15);
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the zone a name.')),
      );
      return;
    }
    if (_points.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draw the zone boundary — tap at least 3 points on the map.')),
      );
      return;
    }
    setState(() => _saving = true);
    final polygon =
        _points.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList();
    final payload = {
      'name': name,
      'polygon': polygon,
      'price_sidewalk': num.tryParse(_sidewalkCtrl.text.trim()) ?? 0,
      'price_driveway': num.tryParse(_drivewayCtrl.text.trim()) ?? 0,
      'price_both': num.tryParse(_bothCtrl.text.trim()) ?? 0,
      'price_salting': num.tryParse(_saltingCtrl.text.trim()) ?? 0,
    };
    try {
      if (widget.zone == null) {
        await _supabase.from('service_areas').insert({...payload, 'is_active': true});
      } else {
        await _supabase.from('service_areas').update(payload).eq('id', widget.zone!['id']);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.zone == null ? 'Add Zone' : 'Edit Zone'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
      body: Column(
        children: [
          // --- Map with polygon drawing ---
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _initialCenter,
                    initialZoom: 13,
                    onTap: (_, point) => setState(() => _points.add(point)),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.snowserv.app',
                    ),
                    if (_points.length >= 3)
                      PolygonLayer(polygons: [
                        Polygon(
                          points: _points,
                          color: SnowServColors.navy.withOpacity(0.20),
                          borderColor: SnowServColors.navy,
                          borderStrokeWidth: 2,
                        ),
                      ]),
                    MarkerLayer(markers: [
                      for (var i = 0; i < _points.length; i++)
                        Marker(
                          point: _points[i],
                          width: 16,
                          height: 16,
                          child: Container(
                            decoration: BoxDecoration(
                              color: i == _points.length - 1 ? Colors.orange : SnowServColors.navy,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                    ]),
                  ],
                ),
                // Address search to jump the map to a location.
                Positioned(
                  top: 8,
                  left: 8,
                  right: 8,
                  child: Material(
                    elevation: 2,
                    borderRadius: BorderRadius.circular(8),
                    child: TextField(
                      controller: _searchCtrl,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _searchAddress(),
                      decoration: InputDecoration(
                        hintText: 'Find a place to center the map…',
                        filled: true,
                        fillColor: Colors.white,
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searching
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            : IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _searchAddress),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ),
                // Drawing controls.
                Positioned(
                  bottom: 8,
                  left: 8,
                  right: 8,
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4)],
                          ),
                          child: Text(
                            _points.isEmpty
                                ? 'Tap the map to place boundary corners.'
                                : '${_points.length} point${_points.length == 1 ? '' : 's'} • tap to add more',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _mapButton(Icons.undo, 'Undo', _points.isEmpty
                          ? null
                          : () => setState(() => _points.removeLast())),
                      const SizedBox(width: 8),
                      _mapButton(Icons.clear, 'Clear', _points.isEmpty
                          ? null
                          : () => setState(_points.clear)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // --- Name + prices ---
          SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(controller: _nameCtrl, decoration: const InputDecoration(labelText: 'Zone name (e.g. Yonkers)')),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(controller: _sidewalkCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Sidewalk \$'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: _drivewayCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Driveway \$'))),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: TextField(controller: _bothCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Both \$'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: _saltingCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Salting \$'))),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapButton(IconData icon, String tooltip, VoidCallback? onTap) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      elevation: 2,
      child: IconButton(
        icon: Icon(icon, color: onTap == null ? Colors.grey : SnowServColors.navy),
        tooltip: tooltip,
        onPressed: onTap,
      ),
    );
  }
}
