import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../theme.dart';
import '../../utils/job_helpers.dart';
import '../../utils/legal.dart';
import '../../utils/geo.dart';
import '../../utils/geocode.dart';
import 'address_screen.dart';
import 'job_history_screen.dart';
import '../faq_screen.dart';
import '../admin/admin_screen.dart';

final supabase = Supabase.instance.client;

// Base URL for Supabase Edge Functions — used to build the mobile Checkout
// return URL (the checkout-return page shown in the in-app browser). The web
// build returns to its own origin instead, so it never uses this.
const _kFunctionsBase = 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1';

class CustomerHome extends StatefulWidget {
  const CustomerHome({super.key});

  @override
  State<CustomerHome> createState() => _CustomerHomeState();
}

class _CustomerHomeState extends State<CustomerHome> {
  String selectedService = 'sidewalk';
  bool salting = false;
  bool loading = false;
  List<Map<String, dynamic>> myJobs = [];
  // jobId -> number of the assigned provider's jobs queued ahead of this one.
  final Map<String, int> _jobsAhead = {};
  Map<String, dynamic>? savedAddress;
  RealtimeChannel? _jobsChannel;
  double surgeMultiplier = 1.0;
  double? snowDepthInches;
  String? _stripeCustomerId;
  Map<String, dynamic>? _savedCard;
  // The active service area (pricing zone) matching the current order address
  // (null = the address isn't in a served zone, or we don't have one yet).
  // Prices come from here.
  Map<String, dynamic>? _serviceArea;
  bool _checkingArea = false;
  // Geocoded order address, cached from the availability check so createJob can
  // reuse it for job_lat/lng without geocoding a second time.
  double? _orderLat;
  double? _orderLng;
  // Debounces availability re-checks while the "someone else" address is typed
  // (each check geocodes, which is rate-limited).
  Timer? _areaDebounce;
  bool _isAdmin = false;
  final Map<String, String> _prevJobStatuses = {};
  bool _completedDialogShowing = false;
  bool orderingForSomeoneElse = false;
  final _otherAddressController = TextEditingController();
  final _otherCityController = TextEditingController();
  final _otherStateController = TextEditingController();
  final _otherZipController = TextEditingController();
  final _customerNotesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadMyJobs();
    loadAddress();
    loadSurge();
    subscribeToJobs();
    _loadSavedCard();
    _loadIsAdmin();
    // Re-check availability (debounced) as the "someone else" address is typed.
    _otherAddressController.addListener(_scheduleAreaRefresh);
    _otherCityController.addListener(_scheduleAreaRefresh);
    _otherStateController.addListener(_scheduleAreaRefresh);
    _otherZipController.addListener(_scheduleAreaRefresh);
    _handleWebCheckoutReturn();
  }

  // On web, Stripe Checkout redirects back to our origin with ?checkout=success|
  // cancel. The order itself is created by the stripe-webhook (and shows up via
  // Realtime / loadMyJobs) — this just confirms the outcome to the customer.
  void _handleWebCheckoutReturn() {
    if (!kIsWeb) return;
    final outcome = Uri.base.queryParameters['checkout'];
    if (outcome == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (outcome == 'success') {
        loadMyJobs();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Order placed! Finding a provider near you...'),
            backgroundColor: Colors.green,
          ),
        );
      } else if (outcome == 'cancel') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Checkout canceled — no charge was made.')),
        );
      }
    });
  }

  // Debounce typing so we geocode at most once the user pauses.
  void _scheduleAreaRefresh() {
    _areaDebounce?.cancel();
    _areaDebounce = Timer(const Duration(milliseconds: 700), _refreshServiceArea);
  }

  @override
  void dispose() {
    _jobsChannel?.unsubscribe();
    _areaDebounce?.cancel();
    _otherAddressController.dispose();
    _otherCityController.dispose();
    _otherStateController.dispose();
    _otherZipController.dispose();
    _customerNotesController.dispose();
    super.dispose();
  }

  Future<void> loadAddress() async {
    try {
      final data = await supabase
          .from('addresses')
          .select()
          .eq('user_id', supabase.auth.currentUser!.id)
          .limit(1);
      if (mounted && data.isNotEmpty) {
        setState(() => savedAddress = data.first);
        _refreshServiceArea();
      }
    } catch (_) {}
  }

  Future<void> _loadIsAdmin() async {
    try {
      final data = await supabase
          .from('profiles')
          .select('is_admin')
          .eq('id', supabase.auth.currentUser!.id)
          .maybeSingle();
      if (mounted && data?['is_admin'] == true) setState(() => _isAdmin = true);
    } catch (_) {}
  }

  Future<void> loadSurge() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      );

      final url =
          'https://api.open-meteo.com/v1/forecast?latitude=${position.latitude}&longitude=${position.longitude}&current=snow_depth&timezone=auto';

      double snowDepthMeters = 0.0;
      try {
        final data = await _fetchWeather(url);
        snowDepthMeters = (data['current']['snow_depth'] ?? 0.0).toDouble();
      } catch (_) {}

      final inches = snowDepthMeters * 39.3701;

      // Storm pricing (formerly "surge") — reflects how much harder the job is
      // at depth, and helps get providers out in bad storms. Contiguous bands:
      // 0-3" 1.0x, 3-6" 1.3x, 6-10" 1.7x, 10"+ 2.3x.
      double multiplier;
      if (inches >= 10) {
        multiplier = 2.3;
      } else if (inches >= 6) {
        multiplier = 1.7;
      } else if (inches >= 3) {
        multiplier = 1.3;
      } else {
        multiplier = 1.0;
      }

      if (mounted) {
        setState(() {
          snowDepthInches = inches;
          surgeMultiplier = multiplier;
        });
      }
    } catch (e) {
      debugPrint('Surge load error: $e');
    }
  }

  Future<Map<String, dynamic>> _fetchWeather(String url) async {
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final body = await response.transform(const Utf8Decoder()).join();
    client.close();
    return jsonDecode(body) as Map<String, dynamic>;
  }

  void subscribeToJobs() {
    final userId = supabase.auth.currentUser!.id;
    _jobsChannel = supabase.channel('customer_jobs_$userId').onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'jobs',
      callback: (payload) {
        loadMyJobs();
        if (!mounted) return;
        final newStatus = payload.newRecord['status'] as String?;
        if (newStatus == 'assigned') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A provider has been assigned to your job!'),
              backgroundColor: Colors.green,
            ),
          );
        } else if (newStatus == 'in_progress') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Your provider has started the job.'),
              backgroundColor: Colors.blue,
            ),
          );
        }
      },
    ).subscribe();
  }

  Future<void> loadMyJobs() async {
    try {
      final data = await supabase
          .from('jobs')
          .select()
          .eq('customer_id', supabase.auth.currentUser!.id)
          .order('created_at', ascending: false);
      if (!mounted) return;
      final newJobs = List<Map<String, dynamic>>.from(data);
      bool jobJustCompleted = false;
      for (final job in newJobs) {
        final jobId = job['id'].toString();
        final newStatus = job['status'] as String? ?? '';
        final oldStatus = _prevJobStatuses[jobId];
        if (oldStatus != null && oldStatus != 'completed' && newStatus == 'completed') {
          jobJustCompleted = true;
        }
        _prevJobStatuses[jobId] = newStatus;
      }
      setState(() => myJobs = newJobs);
      _refreshQueuePositions();
      if (jobJustCompleted) _showJobCompleteDialog();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error loading jobs: $e')));
      }
    }
  }

  // How many of the assigned provider's jobs are queued ahead of each of the
  // customer's active jobs (ordered oldest-first, the way providers work them).
  // Powers the honest "N jobs ahead of you" line instead of a made-up ETA.
  Future<void> _refreshQueuePositions() async {
    final assigned = myJobs.where(
        (j) => j['status'] == 'assigned' && j['provider_id'] != null && j['created_at'] != null);
    final Map<String, int> ahead = {};
    for (final j in assigned) {
      try {
        final rows = await supabase
            .from('jobs')
            .select('id')
            .eq('provider_id', j['provider_id'])
            .inFilter('status', ['assigned', 'in_progress'])
            .lt('created_at', j['created_at']);
        ahead[j['id'].toString()] = (rows as List).length;
      } catch (_) {}
    }
    if (mounted) setState(() => _jobsAhead
      ..clear()
      ..addAll(ahead));
  }

  void _showAccountSheet() {
    showModalBottomSheet(
      context: context,
      // Scrollable with a max height so the menu can never bottom-overflow as
      // entries accumulate (Admin Panel row, legal links...). Same fix as the
      // provider account sheet.
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (_isAdmin) ...[
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings, color: SnowServColors.iceBlue),
                  title: const Text('Admin Panel'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const AdminPanelScreen()));
                  },
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
              ],
              ListTile(
                leading: const Icon(Icons.email_outlined, color: SnowServColors.navy),
                title: const Text('Contact Support'),
                subtitle: const Text('support@snowserv.app'),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri(
                    scheme: 'mailto',
                    path: 'support@snowserv.app',
                    queryParameters: {'subject': 'SnowServ Support Request'},
                  );
                  final launched = await launchUrl(uri);
                  if (!launched && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Email us at support@snowserv.app'),
                        duration: Duration(seconds: 5),
                      ),
                    );
                  }
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.help_outline, color: SnowServColors.navy),
                title: const Text('Help & FAQ'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqScreen()));
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ...legalMenuTiles(context),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text('Log Out', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  supabase.auth.signOut();
                },
              ),
            ],
          ),
        ),
          ),
        ),
      ),
    );
  }

  void _showJobCompleteDialog() {
    if (_completedDialogShowing || !mounted) return;
    _completedDialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Job Complete!'),
        content: const Text('Your service has been completed. Go to My Orders to view your receipt and rate your experience.'),
        actions: [
          TextButton(
            onPressed: () {
              _completedDialogShowing = false;
              Navigator.pop(context);
            },
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              _completedDialogShowing = false;
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => const CustomerJobHistoryScreen(),
              ));
            },
            child: const Text('View Receipt'),
          ),
        ],
      ),
    );
  }

  // Prices come from the matched service area (0 when no area / unserved ZIP).
  int get _priceSidewalk => (_serviceArea?['price_sidewalk'] as num?)?.round() ?? 0;
  int get _priceDriveway => (_serviceArea?['price_driveway'] as num?)?.round() ?? 0;
  int get _priceBoth => (_serviceArea?['price_both'] as num?)?.round() ?? 0;
  int get _priceSalting => (_serviceArea?['price_salting'] as num?)?.round() ?? 0;

  // The ZIP for the current order — the "someone else" address when that toggle
  // is on, otherwise the customer's saved address. Used for waitlist capture and
  // as a legacy fallback when a zone has no polygon yet.
  String? get _orderZip {
    final z = orderingForSomeoneElse
        ? _otherZipController.text.trim()
        : savedAddress?['zip']?.toString().trim();
    return (z == null || z.isEmpty) ? null : z;
  }

  // The full order address (map) to geocode, or null if it's not complete
  // enough to price yet.
  Map<String, dynamic>? get _orderAddressForGeo {
    if (orderingForSomeoneElse) {
      final line = _otherAddressController.text.trim();
      final city = _otherCityController.text.trim();
      final state = _otherStateController.text.trim();
      final zip = _otherZipController.text.trim();
      if (line.isEmpty || city.isEmpty || state.isEmpty || zip.length < 5) return null;
      return {'address_line': line, 'city': city, 'state': state, 'zip': zip};
    }
    final a = savedAddress;
    if (a == null) return null;
    return {
      'address_line': a['address_line'],
      'city': a['city'],
      'state': a['state'],
      'zip': a['zip'],
    };
  }

  bool get _orderAddressReady => _orderAddressForGeo != null;

  // Geocode the current order address and match it to an active pricing zone
  // (polygon geofence, with a legacy ZIP fallback). Caches the geocoded point
  // so createJob can reuse it for job_lat/lng.
  Future<void> _refreshServiceArea() async {
    final addr = _orderAddressForGeo;
    if (addr == null) {
      if (mounted) {
        setState(() {
          _serviceArea = null;
          _orderLat = null;
          _orderLng = null;
          _checkingArea = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _checkingArea = true);
    try {
      final geo = await geocodeAddress(addr);
      final rows = await supabase.from('service_areas').select().eq('is_active', true);
      final zones = (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
      final match = matchZone(geo?['lat'], geo?['lng'], zip: _orderZip, zones: zones);
      if (!mounted) return;
      setState(() {
        _serviceArea = match;
        _orderLat = geo?['lat'];
        _orderLng = geo?['lng'];
        _checkingArea = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _serviceArea = null;
          _orderLat = null;
          _orderLng = null;
          _checkingArea = false;
        });
      }
    }
  }

  Future<void> _joinWaitlist() async {
    try {
      await supabase.from('waitlist').insert({
        'email': supabase.auth.currentUser?.email,
        'zip': _orderZip,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You're on the waitlist — we'll email you when we reach your area.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join waitlist: $e')));
      }
    }
  }

  int getBasePrice() {
    switch (selectedService) {
      case 'sidewalk': return _priceSidewalk;
      case 'driveway': return _priceDriveway;
      case 'sidewalk_driveway': return _priceBoth;
      default: return 0;
    }
  }

  int getTotalBase() {
    int total = getBasePrice();
    if (salting) total += _priceSalting;
    return total;
  }

  int getFinalPrice() {
    return (getTotalBase() * surgeMultiplier).round();
  }

  Widget _buildNotAvailableBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.location_off, color: Colors.orange),
              SizedBox(width: 8),
              Expanded(
                child: Text('Not available in your area yet',
                    style: TextStyle(fontWeight: FontWeight.bold, color: SnowServColors.navy)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            "SnowServ isn't in your area yet — but we're expanding. Join the waitlist and "
            "we'll notify you the moment we arrive.",
            style: TextStyle(fontSize: 13, color: Colors.black87),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _joinWaitlist,
              icon: const Icon(Icons.notifications_active_outlined, size: 18),
              label: const Text('Join the waitlist'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadSavedCard() async {
    try {
      final userData = await supabase
          .from('users')
          .select('stripe_customer_id, card_pm_id, card_last4, card_brand, card_exp_month, card_exp_year')
          .eq('id', supabase.auth.currentUser!.id)
          .maybeSingle();
      if (userData == null) return;
      final customerId = userData['stripe_customer_id'] as String?;
      if (customerId != null) _stripeCustomerId = customerId;
      final pmId = userData['card_pm_id'] as String?;
      if (pmId != null && mounted) {
        setState(() => _savedCard = {
          'id': pmId,
          'last4': userData['card_last4'],
          'brand': userData['card_brand'],
          'exp_month': userData['card_exp_month'],
          'exp_year': userData['card_exp_year'],
        });
      }
    } catch (e) {
      debugPrint('Load saved card error: $e');
    }
  }

  // Normalized address key for duplicate comparison (case/whitespace-insensitive).
  String _addrKey(Map addr) => [
        addr['address_line'],
        addr['city'],
        addr['state'],
        addr['zip'],
      ].map((v) => (v ?? '').toString().trim().toLowerCase()).join('|');

  // True if the customer already has an active (requested/assigned/in_progress)
  // order at the same address. Fail-open: returns false on any error so a
  // hiccup in the check never blocks a legitimate order.
  Future<bool> _hasActiveOrderForAddress(Map addr) async {
    try {
      final uid = supabase.auth.currentUser!.id;
      final active = await supabase
          .from('jobs')
          .select('id, address_id')
          .eq('customer_id', uid)
          .inFilter('status', ['requested', 'assigned', 'in_progress']);
      if (active.isEmpty) return false;
      final ids = active.map((j) => j['address_id']).where((x) => x != null).toList();
      if (ids.isEmpty) return false;
      final addrs = await supabase
          .from('addresses')
          .select('id, address_line, city, state, zip')
          .inFilter('id', ids);
      final byId = {for (final a in addrs) a['id'].toString(): a};
      final key = _addrKey(addr);
      return active.any((j) {
        final a = byId[j['address_id']?.toString()];
        return a != null && _addrKey(a) == key;
      });
    } catch (e) {
      debugPrint('Duplicate-order check failed (allowing order): $e');
      return false;
    }
  }

  Future<void> createJob() async {
    // Block suspended accounts before any other processing
    final userData = await supabase
        .from('users')
        .select('is_suspended')
        .eq('id', supabase.auth.currentUser!.id)
        .maybeSingle();
    if (userData != null && userData['is_suspended'] == true) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.block, color: Colors.red),
                SizedBox(width: 8),
                Text('Account Suspended'),
              ],
            ),
            content: const Text(
              'Your account has been suspended and you are unable to place orders. '
              'Please contact support at support@snowserv.app for assistance.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (!orderingForSomeoneElse && savedAddress == null) {
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const AddressScreen()),
      );
      if (result == true) await loadAddress();
      return;
    }
    if (orderingForSomeoneElse) {
      if (_otherAddressController.text.trim().isEmpty ||
          _otherCityController.text.trim().isEmpty ||
          _otherStateController.text.trim().isEmpty ||
          _otherZipController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please fill in the service address for this order.')),
        );
        return;
      }
    }

    // Availability gate — a matching active service area is required to order.
    if (_serviceArea == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not available in your area yet.')),
      );
      return;
    }

    // Duplicate-order guard: one active order per address. Blocks placing a new
    // order for an address that already has an active (requested/assigned/
    // in_progress) job. Fail-open — if the check errors, allow the order.
    final currentAddr = orderingForSomeoneElse
        ? {
            'address_line': _otherAddressController.text.trim(),
            'city': _otherCityController.text.trim(),
            'state': _otherStateController.text.trim(),
            'zip': _otherZipController.text.trim(),
          }
        : savedAddress!;
    if (await _hasActiveOrderForAddress(currentAddr)) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Row(children: [
              Icon(Icons.info_outline, color: SnowServColors.iceBlue),
              SizedBox(width: 8),
              Text('Order already active'),
            ]),
            content: const Text(
              'You already have an active order for this address. Please wait for '
              'it to finish, or cancel it, before placing a new order.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
            ],
          ),
        );
      }
      return;
    }

    setState(() => loading = true);
    try {
      final amountCents = getFinalPrice() * 100;
      final services = <String>[];
      if (selectedService == 'sidewalk' || selectedService == 'sidewalk_driveway') services.add('Sidewalk');
      if (selectedService == 'driveway' || selectedService == 'sidewalk_driveway') services.add('Driveway');
      if (salting) services.add('Salting');
      final description = 'SnowServ: ${services.join(' + ')}';

      // Geocode the service address (reuse the point cached during the
      // availability check; geocode once more only if we somehow don't have it).
      double? jobLat = _orderLat;
      double? jobLng = _orderLng;
      if (jobLat == null || jobLng == null) {
        final addressForGeo = _orderAddressForGeo;
        final geo = addressForGeo != null ? await geocodeAddress(addressForGeo) : null;
        jobLat = geo?['lat'];
        jobLng = geo?['lng'];
      }

      final notes = _customerNotesController.text.trim();
      final userId = supabase.auth.currentUser!.id;

      // Everything the stripe-webhook needs to create the job AFTER payment is
      // authorized. The job is NOT inserted here — creating it server-side keeps
      // the order alive across the Checkout redirect (the web app reloads on
      // return) and even if the customer closes the tab. For "ordering for
      // someone else" the raw address rides along so the webhook inserts it —
      // no orphan address row if the customer abandons Checkout.
      final metadata = <String, dynamic>{
        'customer_id': userId,
        'address_mode': orderingForSomeoneElse ? 'new' : 'saved',
        'walkway': (selectedService == 'sidewalk' || selectedService == 'sidewalk_driveway').toString(),
        'driveway': (selectedService == 'driveway' || selectedService == 'sidewalk_driveway').toString(),
        'salting': salting.toString(),
        'base_price': getTotalBase().toString(),
        'surge_multiplier': surgeMultiplier.toString(),
        'final_price': getFinalPrice().toString(),
        if (notes.isNotEmpty) 'customer_notes': notes,
        if (jobLat != null) 'job_lat': jobLat.toString(),
        if (jobLng != null) 'job_lng': jobLng.toString(),
      };
      if (orderingForSomeoneElse) {
        metadata['addr_line'] = _otherAddressController.text.trim();
        metadata['addr_city'] = _otherCityController.text.trim();
        metadata['addr_state'] = _otherStateController.text.trim();
        metadata['addr_zip'] = _otherZipController.text.trim();
      } else {
        metadata['address_id'] = savedAddress!['id'].toString();
      }

      // Platform-appropriate return URLs. Web returns to the app's own origin so
      // it reloads and shows the new job; mobile lands on the checkout-return
      // page shown inside the in-app browser.
      final String successUrl;
      final String cancelUrl;
      if (kIsWeb) {
        final origin = Uri.base.origin;
        successUrl = '$origin/?checkout=success';
        cancelUrl = '$origin/?checkout=cancel';
      } else {
        successUrl = '$_kFunctionsBase/checkout-return?status=success';
        cancelUrl = '$_kFunctionsBase/checkout-return?status=cancel';
      }

      final sessionResponse = await supabase.functions.invoke(
        'create-checkout-session',
        body: {
          'amount_cents': amountCents,
          'job_description': description,
          if (_stripeCustomerId != null) 'stripe_customer_id': _stripeCustomerId,
          'user_email': supabase.auth.currentUser?.email,
          'success_url': successUrl,
          'cancel_url': cancelUrl,
          'metadata': metadata,
        },
      );
      final checkoutUrl = sessionResponse.data?['url'] as String?;
      if (checkoutUrl == null) throw Exception('Payment setup failed: ${sessionResponse.data}');
      final returnedCustomerId = sessionResponse.data?['stripe_customer_id'] as String?;
      if (returnedCustomerId != null) _stripeCustomerId = returnedCustomerId;

      // Open the hosted Stripe Checkout page. Web = same-tab redirect (the app
      // reloads on return); mobile = in-app browser. The job is created by the
      // stripe-webhook once payment is authorized, then dispatched server-side —
      // so we neither insert the job nor dispatch here anymore.
      final uri = Uri.parse(checkoutUrl);
      if (kIsWeb) {
        await launchUrl(uri, webOnlyWindowName: '_self');
        return; // Navigating away; nothing else to do on web.
      }
      final launched = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      if (!launched) throw Exception('Could not open the payment page.');
      if (mounted) {
        setState(() {
          orderingForSomeoneElse = false;
          _otherAddressController.clear();
          _otherCityController.clear();
          _otherStateController.clear();
          _otherZipController.clear();
          _customerNotesController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Finish in the browser to place your order — it will appear '
                "here once it's placed. You're not charged until a provider starts."),
            duration: Duration(seconds: 6),
          ),
        );
      }
      // Realtime shows the webhook-created job automatically; refresh too in case
      // Realtime is momentarily disconnected.
      await loadMyJobs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e'), duration: const Duration(seconds: 8)));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget serviceButton(String key, String label, int price, IconData icon) {
    final isSelected = selectedService == key;
    return GestureDetector(
      onTap: () => setState(() => selectedService = key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? SnowServColors.iceBlue : Colors.white,
          border: Border.all(
            color: isSelected ? SnowServColors.iceBlue : SnowServColors.glacier,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(12),
          boxShadow: isSelected
              ? [BoxShadow(color: SnowServColors.iceBlue.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))]
              : [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))],
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.white : SnowServColors.iceBlue, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.white : SnowServColors.navy,
                ),
              ),
            ),
            Text(
              '\$$price',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : SnowServColors.iceBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget statusBadge(String status) {
    Color color;
    String label;
    IconData icon;
    switch (status) {
      case 'requested':
        color = Colors.orange;
        label = 'Finding provider...';
        icon = Icons.search;
        break;
      case 'assigned':
        color = SnowServColors.iceBlue;
        label = 'Provider assigned';
        icon = Icons.person_pin;
        break;
      case 'in_progress':
        color = Colors.green;
        label = 'In progress';
        icon = Icons.electric_bolt;
        break;
      case 'completed':
        color = Colors.grey;
        label = 'Completed';
        icon = Icons.check_circle;
        break;
      case 'cancelled':
        color = Colors.red;
        label = 'Cancelled';
        icon = Icons.cancel;
        break;
      default:
        color = Colors.grey;
        label = status;
        icon = Icons.circle;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> cancelJob(String jobId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Request?'),
        content: const Text('Are you sure you want to cancel? If a provider has already been assigned, they will be notified.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final job = myJobs.firstWhere((j) => j['id'].toString() == jobId, orElse: () => {});
      String? refundAction;
      if (job['payment_intent_id'] != null) {
        final resp = await supabase.functions.invoke('refund-job', body: {'job_id': jobId});
        final data = resp.data;
        if (data is Map && data['action'] is String) {
          refundAction = data['action'] as String;
        }
      }
      await supabase.from('jobs').update({
        'status': 'cancelled',
        'dispatched_to': null,
        'dispatched_at': null,
      }).eq('id', jobId);
      supabase.functions.invoke('notify-provider', body: {'job_id': jobId, 'status': 'cancelled'});
      loadMyJobs();
      if (mounted) {
        // A released hold clears fast; a real refund (a provider had accepted)
        // takes the bank's usual 5–10 days.
        final message = refundAction == 'refunded'
            ? 'Request cancelled. Your refund will appear in 5–10 business days.'
            : 'Request cancelled. The pending hold on your card will drop off shortly — you were never charged.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Text('❄  SnowServ', style: TextStyle(letterSpacing: 1)),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.receipt_long, color: Colors.white, size: 18),
            label: const Text('My Orders', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerJobHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () async {
              await Future.wait([loadMyJobs(), loadAddress(), _loadSavedCard()]);
              loadSurge();
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Account',
            onPressed: () => _showAccountSheet(),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Builder(builder: (context) {
              final activeJobs = myJobs.where((j) =>
                j['status'] == 'requested' ||
                j['status'] == 'assigned' ||
                j['status'] == 'in_progress'
              ).toList();
              if (activeJobs.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Active Jobs',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
                  const SizedBox(height: 8),
                  ...activeJobs.map((job) {
                final canCancel = job['status'] == 'requested' || job['status'] == 'assigned';
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (job['job_number'] != null)
                                    Text('Job #${job['job_number']}',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                            fontWeight: FontWeight.w500)),
                                  Text(describeJob(job),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                          color: SnowServColors.navy)),
                                  const SizedBox(height: 4),
                                  Text(
                                    '\$${job['final_price'] ?? job['base_price'] ?? 0}',
                                    style: const TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15),
                                  ),
                                ],
                              ),
                            ),
                            statusBadge(job['status']),
                          ],
                        ),
                        // Honest queue position instead of a made-up minute ETA:
                        // "N jobs ahead of you" / "You're next" once we know the
                        // provider's backlog; nothing until it's computed.
                        if (job['status'] == 'assigned' &&
                            _jobsAhead.containsKey(job['id'].toString())) ...[
                          const SizedBox(height: 8),
                          Builder(builder: (_) {
                            final ahead = _jobsAhead[job['id'].toString()]!;
                            return Row(
                              children: [
                                Icon(ahead > 0 ? Icons.people_outline : Icons.local_shipping_outlined,
                                    size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(
                                  ahead > 0
                                      ? '$ahead job${ahead == 1 ? '' : 's'} ahead of you'
                                      : "You're next — your provider is on the way",
                                  style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600),
                                ),
                              ],
                            );
                          }),
                        ],
                        if (job['status'] == 'in_progress') ...[
                          const SizedBox(height: 8),
                          Row(
                            children: const [
                              Icon(Icons.ac_unit, size: 14, color: Colors.grey),
                              SizedBox(width: 4),
                              Text(
                                'Your provider is working on your job',
                                style: TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ],
                        // High-demand reassurance: shown when the job is still
                        // unclaimed and has already been offered around (no
                        // driver currently holds it, but some have passed). Keeps
                        // the customer informed instead of an endless silent wait.
                        if (job['status'] == 'requested' &&
                            job['dispatched_to'] == null &&
                            ((job['rejected_providers'] as List?)?.isNotEmpty ?? false)) ...[
                          const SizedBox(height: 8),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: const [
                              Icon(Icons.hourglass_bottom, size: 14, color: Colors.grey),
                              SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  "It's busy right now — we're still finding you an available provider. "
                                  "Hang tight; you'll be notified the moment someone accepts.",
                                  style: TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (canCancel) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => cancelJob(job['id'].toString()),
                              icon: const Icon(Icons.cancel_outlined, size: 16),
                              label: const Text('Cancel Request'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: const BorderSide(color: Colors.red),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
                  }),
                  const Divider(height: 28),
                ],
              );
            }),

            const Text('Request Service',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
            const SizedBox(height: 10),

            if (savedAddress != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SnowServColors.glacier),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on, size: 16, color: SnowServColors.iceBlue),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${savedAddress!['address_line']}, ${savedAddress!['city']}, ${savedAddress!['state']} ${savedAddress!['zip']}',
                        style: const TextStyle(color: Colors.black87, fontSize: 13),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final result = await Navigator.push<bool>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddressScreen(existingAddress: savedAddress),
                          ),
                        );
                        if (result == true) loadAddress();
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
              )
            else
              OutlinedButton.icon(
                onPressed: () async {
                  final result = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(builder: (_) => const AddressScreen()),
                  );
                  if (result == true) loadAddress();
                },
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Add your address'),
              ),

            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                setState(() => orderingForSomeoneElse = !orderingForSomeoneElse);
                _refreshServiceArea();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: orderingForSomeoneElse ? Colors.purple.shade50 : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: orderingForSomeoneElse ? Colors.purple.shade300 : SnowServColors.glacier,
                    width: orderingForSomeoneElse ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.people_alt_outlined,
                        size: 18,
                        color: orderingForSomeoneElse ? Colors.purple : Colors.grey),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ordering for someone else?',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: orderingForSomeoneElse ? Colors.purple : SnowServColors.navy,
                            ),
                          ),
                          Text(
                            'Send snow removal to a friend or family member at a different address',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: orderingForSomeoneElse,
                      activeColor: Colors.purple,
                      onChanged: (val) {
                        setState(() => orderingForSomeoneElse = val);
                        _refreshServiceArea();
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (orderingForSomeoneElse) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.purple.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.purple.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Service Address for This Order',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.purple)),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _otherAddressController,
                      decoration: const InputDecoration(
                        labelText: 'Street Address',
                        prefixIcon: Icon(Icons.home_outlined),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _otherCityController,
                            decoration: const InputDecoration(
                              labelText: 'City',
                              filled: true,
                              fillColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _otherStateController,
                            decoration: const InputDecoration(
                              labelText: 'State',
                              filled: true,
                              fillColor: Colors.white,
                            ),
                            textCapitalization: TextCapitalization.characters,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _otherZipController,
                            decoration: const InputDecoration(
                              labelText: 'ZIP',
                              filled: true,
                              fillColor: Colors.white,
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            // Availability gate: prices + ordering only appear for a served ZIP.
            if (_checkingArea)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Row(children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Checking availability in your area…', style: TextStyle(color: Colors.grey)),
                ]),
              ),
            if (!_checkingArea && orderingForSomeoneElse && !_orderAddressReady)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text('Enter the service address above to see pricing.',
                    style: TextStyle(color: Colors.grey)),
              ),
            if (!_checkingArea && _orderAddressReady && _serviceArea == null)
              _buildNotAvailableBanner(),
            if (_serviceArea != null) ...[
              const SizedBox(height: 16),
              serviceButton('sidewalk', 'Sidewalk Only', _priceSidewalk, Icons.directions_walk),
              serviceButton('driveway', 'Driveway Only', _priceDriveway, Icons.directions_car),
              serviceButton('sidewalk_driveway', 'Sidewalk + Driveway', _priceBoth, Icons.home),

            const SizedBox(height: 16),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: salting ? SnowServColors.iceBlue : SnowServColors.glacier, width: 2),
                ),
                child: SwitchListTile(
                  title: const Text('Add Salting',
                      style: TextStyle(fontWeight: FontWeight.w600, color: SnowServColors.navy)),
                  subtitle: Text('+\$$_priceSalting', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                  value: salting,
                  activeColor: SnowServColors.iceBlue,
                  onChanged: (val) => setState(() => salting = val),
                ),
              ),
            ),

            const SizedBox(height: 24),
            if (snowDepthInches != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: surgeMultiplier > 1.0 ? Colors.orange.shade50 : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: surgeMultiplier > 1.0 ? Colors.orange.shade300 : Colors.blue.shade200,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      surgeMultiplier > 1.0 ? Icons.bolt : Icons.ac_unit,
                      color: surgeMultiplier > 1.0 ? Colors.orange : Colors.blue,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            surgeMultiplier > 1.0
                                ? 'Storm Pricing — ${surgeMultiplier}x'
                                : 'Snow Conditions',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: surgeMultiplier > 1.0 ? Colors.orange : Colors.blue,
                                fontSize: 14),
                          ),
                          Text(
                            snowDepthInches! == 0
                                ? 'No snow on the ground — standard pricing'
                                : '${snowDepthInches!.toStringAsFixed(1)}" of snow on the ground'
                                    '${surgeMultiplier > 1.0 ? ' — storm pricing active' : ''}',
                            style: TextStyle(
                              color: surgeMultiplier > 1.0 ? Colors.orange : Colors.blue,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: surgeMultiplier > 1.0 ? Colors.orange.shade300 : SnowServColors.glacier,
                ),
              ),
              child: Column(
                children: [
                  if (surgeMultiplier > 1.0) ...[
                    Text(
                      '\$${getTotalBase()}',
                      style: const TextStyle(
                        fontSize: 18,
                        color: Colors.grey,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text('Total', style: TextStyle(color: Colors.grey, fontSize: 13)),
                  Text(
                    '\$${getFinalPrice()}',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: surgeMultiplier > 1.0 ? Colors.orange : SnowServColors.navy,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            TextField(
              controller: _customerNotesController,
              maxLines: 2,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Notes for provider (optional)',
                hintText: 'e.g. Side gate is unlocked, dog in backyard...',
                prefixIcon: Icon(Icons.notes_outlined),
              ),
            ),
            const SizedBox(height: 12),
            // Reassure the customer this places a hold, not a charge. (Used to
            // live in the in-app payment sheet, which Stripe Checkout replaced.)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SnowServColors.frost,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: SnowServColors.glacier),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Icon(Icons.lock_clock_outlined, size: 18, color: SnowServColors.iceBlue),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "You'll pay securely on the next screen. This places a hold — "
                      "you're only charged when a provider starts the job, so if you "
                      "cancel before then, you're never charged.",
                      style: TextStyle(fontSize: 12, color: SnowServColors.navy, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            if (_savedCard != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.credit_card, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  Text(
                    'Card on file ${(_savedCard!['brand'] ?? '').toString().toUpperCase()} '
                    '•••• ${_savedCard!['last4']} — change it at checkout',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: loading ? null : createJob,
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Request Service'),
            ),
            const SizedBox(height: 20),
            ],
          ],
        ),
      ),
      ),
    );
  }
}
