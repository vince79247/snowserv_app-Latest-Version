import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_stripe/flutter_stripe.dart' hide Card;
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../theme.dart';
import 'address_screen.dart';
import 'job_history_screen.dart';

final supabase = Supabase.instance.client;

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
  Map<String, dynamic>? savedAddress;
  RealtimeChannel? _jobsChannel;
  double surgeMultiplier = 1.0;
  double? snowDepthInches;
  double? _currentLat;
  double? _currentLng;
  String? _stripeCustomerId;
  Map<String, dynamic>? _savedCard;
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
  }

  @override
  void dispose() {
    _jobsChannel?.unsubscribe();
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
      }
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
      _currentLat = position.latitude;
      _currentLng = position.longitude;

      final url =
          'https://api.open-meteo.com/v1/forecast?latitude=${position.latitude}&longitude=${position.longitude}&current=snow_depth&timezone=auto';

      double snowDepthMeters = 0.0;
      try {
        final data = await _fetchWeather(url);
        snowDepthMeters = (data['current']['snow_depth'] ?? 0.0).toDouble();
      } catch (_) {}

      final inches = snowDepthMeters * 39.3701;

      double multiplier;
      if (inches >= 18) {
        multiplier = 2.0;
      } else if (inches >= 13) {
        multiplier = 1.5;
      } else if (inches >= 8) {
        multiplier = 1.25;
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
      if (jobJustCompleted) _showJobCompleteDialog();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error loading jobs: $e')));
      }
    }
  }

  void _showAccountSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
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

  int getBasePrice() {
    switch (selectedService) {
      case 'sidewalk': return 50;
      case 'driveway': return 100;
      case 'sidewalk_driveway': return 125;
      default: return 0;
    }
  }

  int getTotalBase() {
    int total = getBasePrice();
    if (salting) total += 40;
    return total;
  }

  int getFinalPrice() {
    return (getTotalBase() * surgeMultiplier).round();
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

  Future<void> rateJob(String jobId, String? providerId, int stars) async {
    try {
      await supabase.from('jobs').update({'customer_rating': stars}).eq('id', jobId);
      if (providerId != null) {
        final ratedJobs = await supabase
            .from('jobs')
            .select('customer_rating')
            .eq('provider_id', providerId)
            .not('customer_rating', 'is', null);
        if (ratedJobs.isNotEmpty) {
          final ratings = (ratedJobs as List)
              .map((j) => (j['customer_rating'] as num?)?.toDouble() ?? 0.0)
              .toList();
          final avg = ratings.reduce((a, b) => a + b) / ratings.length;
          await supabase.from('providers').update({
            'rating': double.parse(avg.toStringAsFixed(1)),
          }).eq('id', providerId);
        }
      }
      loadMyJobs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rating failed: $e')));
      }
    }
  }

  Future<Map<String, double>?> _geocodeAddress(Map<String, dynamic> address) async {
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

  Future<void> _dispatchToNearest(String jobId, List<dynamic> rejected, double? lat, double? lng) async {
    try {
      final providers = await supabase
          .from('providers')
          .select('id, current_lat, current_lng')
          .eq('is_online', true)
          .eq('registration_status', 'approved');

      // Count active jobs per provider and grab their current job's location
      final activeJobs = await supabase
          .from('jobs')
          .select('provider_id, job_lat, job_lng')
          .inFilter('status', ['assigned', 'in_progress']);

      final Map<String, Map<String, dynamic>> providerActiveJob = {};
      for (final job in activeJobs as List) {
        final pid = job['provider_id']?.toString();
        if (pid != null) {
          providerActiveJob[pid] = (providerActiveJob[pid] == null)
              ? {'count': 1, 'job_lat': job['job_lat'], 'job_lng': job['job_lng']}
              : {'count': (providerActiveJob[pid]!['count'] as int) + 1, 'job_lat': job['job_lat'], 'job_lng': job['job_lng']};
        }
      }

      // Exclude rejected and providers already at queue cap (2 active jobs)
      final available = (providers as List)
          .where((p) {
            if (rejected.contains(p['id'].toString())) return false;
            final activeCount = providerActiveJob[p['id'].toString()]?['count'] as int? ?? 0;
            return activeCount < 2;
          })
          .toList();

      if (available.isEmpty) return;

      if (lat != null && lng != null) {
        available.sort((a, b) {
          // Providers with an active job: measure from that job's location (where they'll finish)
          // Providers with no active job: measure from their current GPS
          final aInfo = providerActiveJob[a['id'].toString()];
          final bInfo = providerActiveJob[b['id'].toString()];
          final aLat = (aInfo != null && aInfo['job_lat'] != null)
              ? (aInfo['job_lat'] as num).toDouble()
              : (a['current_lat'] ?? 0).toDouble();
          final aLng = (aInfo != null && aInfo['job_lng'] != null)
              ? (aInfo['job_lng'] as num).toDouble()
              : (a['current_lng'] ?? 0).toDouble();
          final bLat = (bInfo != null && bInfo['job_lat'] != null)
              ? (bInfo['job_lat'] as num).toDouble()
              : (b['current_lat'] ?? 0).toDouble();
          final bLng = (bInfo != null && bInfo['job_lng'] != null)
              ? (bInfo['job_lng'] as num).toDouble()
              : (b['current_lng'] ?? 0).toDouble();
          return _dist2(lat, lng, aLat, aLng).compareTo(_dist2(lat, lng, bLat, bLng));
        });
      }

      await supabase.from('jobs').update({
        'dispatched_to': available.first['id'],
        'dispatched_at': DateTime.now().toUtc().toIso8601String(),
        if (lat != null) 'job_lat': lat,
        if (lng != null) 'job_lng': lng,
      }).eq('id', jobId);
    } catch (e) {
      debugPrint('Dispatch error: $e');
    }
  }

  double _dist2(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat2 - lat1;
    final dlng = (lng2 - lng1) * 0.7;
    return dlat * dlat + dlng * dlng;
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
    setState(() => loading = true);
    try {
      final amountCents = getFinalPrice() * 100;
      final services = <String>[];
      if (selectedService == 'sidewalk' || selectedService == 'sidewalk_driveway') services.add('Sidewalk');
      if (selectedService == 'driveway' || selectedService == 'sidewalk_driveway') services.add('Driveway');
      if (salting) services.add('Salting');
      final description = 'SnowServ: ${services.join(' + ')}';

      final intentResponse = await supabase.functions.invoke(
        'create-payment-intent',
        body: {
          'amount_cents': amountCents,
          'job_description': description,
          if (_stripeCustomerId != null) 'stripe_customer_id': _stripeCustomerId,
          if (_stripeCustomerId == null) 'user_email': supabase.auth.currentUser?.email,
          if (_savedCard != null) 'payment_method_id': _savedCard!['id'],
        },
      );
      final clientSecret = intentResponse.data['client_secret'] as String?;
      final returnedCustomerId = intentResponse.data['stripe_customer_id'] as String?;
      final paymentIntentId = intentResponse.data['payment_intent_id'] as String?;
      if (clientSecret == null) throw Exception('Payment setup failed: ${intentResponse.data}');


      if (!mounted) return;
      final paid = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _PaymentSheet(
          clientSecret: clientSecret,
          amount: getFinalPrice(),
          description: description,
          savedCard: _savedCard,
          onSaveCard: (shouldSave, cardDetails) async {
            if (!shouldSave || cardDetails == null) return;
            try {
              final userId = supabase.auth.currentUser?.id;
              if (userId == null) {
                debugPrint('Save card: no current user');
                return;
              }
              debugPrint('Saving card for user $userId: ${cardDetails['id']}');
              final rows = await supabase.from('users').update({
                if (returnedCustomerId != null) 'stripe_customer_id': returnedCustomerId,
                'card_pm_id': cardDetails['id'],
                'card_last4': cardDetails['last4'],
                'card_brand': cardDetails['brand'],
                'card_exp_month': cardDetails['exp_month'],
                'card_exp_year': cardDetails['exp_year'],
              }).eq('id', userId).select('card_pm_id');
              debugPrint('Card save result: $rows');
              if (rows.isEmpty) {
                debugPrint('Card save: update matched 0 rows (RLS or ID mismatch)');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Card not saved — permission issue. Check Supabase RLS.'), backgroundColor: Colors.red),
                  );
                }
                return;
              }
              if (returnedCustomerId != null) _stripeCustomerId = returnedCustomerId;
              if (mounted) {
                setState(() => _savedCard = cardDetails);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Card saved!'), backgroundColor: Colors.green),
                );
              }
            } catch (e) {
              debugPrint('Save card error: $e');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Card save failed: $e'), backgroundColor: Colors.red),
                );
              }
            }
          },
        ),
      );
      if (paid != true) {
        setState(() => loading = false);
        return;
      }

      String addressId;
      if (orderingForSomeoneElse) {
        final addr = await supabase.from('addresses').insert({
          'user_id': supabase.auth.currentUser!.id,
          'address_line': _otherAddressController.text.trim(),
          'city': _otherCityController.text.trim(),
          'state': _otherStateController.text.trim(),
          'zip': _otherZipController.text.trim(),
        }).select('id').single();
        addressId = addr['id'].toString();
      } else {
        addressId = savedAddress!['id'].toString();
      }

      final notes = _customerNotesController.text.trim();

      final addressForGeo = orderingForSomeoneElse ? {
        'address_line': _otherAddressController.text.trim(),
        'city': _otherCityController.text.trim(),
        'state': _otherStateController.text.trim(),
        'zip': _otherZipController.text.trim(),
      } : savedAddress;
      final geo = addressForGeo != null ? await _geocodeAddress(addressForGeo) : null;
      final jobLat = geo?['lat'];
      final jobLng = geo?['lng'];

      final result = await supabase.from('jobs').insert({
        'status': 'requested',
        'customer_id': supabase.auth.currentUser!.id,
        'address_id': addressId,
        'walkway': selectedService == 'sidewalk' || selectedService == 'sidewalk_driveway',
        'driveway': selectedService == 'driveway' || selectedService == 'sidewalk_driveway',
        'salting': salting,
        'base_price': getTotalBase(),
        'surge_multiplier': surgeMultiplier,
        'final_price': getFinalPrice(),
        if (paymentIntentId != null) 'payment_intent_id': paymentIntentId,
        if (notes.isNotEmpty) 'customer_notes': notes,
        if (jobLat != null) 'job_lat': jobLat,
        if (jobLng != null) 'job_lng': jobLng,
      }).select('id').single();

      supabase.functions.invoke('notify-providers', body: {'job_id': result['id']});
      await _dispatchToNearest(result['id'].toString(), [], jobLat, jobLng);
      await loadMyJobs();
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
          const SnackBar(content: Text('Request placed! Finding a provider near you...')),
        );
      }
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
      if (job['payment_intent_id'] != null) {
        await supabase.functions.invoke('refund-job', body: {'job_id': jobId});
      }
      await supabase.from('jobs').update({
        'status': 'cancelled',
        'dispatched_to': null,
        'dispatched_at': null,
      }).eq('id', jobId);
      supabase.functions.invoke('notify-provider', body: {'job_id': jobId, 'status': 'cancelled'});
      loadMyJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request cancelled. Your refund will appear in 5–10 business days.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  String describeJob(Map<String, dynamic> job) {
    final List<String> services = [];
    if (job['driveway'] == true) services.add('Driveway');
    if (job['walkway'] == true) services.add('Sidewalk');
    if (job['salting'] == true) services.add('Salting');
    return services.isEmpty ? 'Service' : services.join(' + ');
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
                        if (job['status'] == 'assigned' && job['eta_minutes'] != null) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Icon(Icons.access_time, size: 14, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text(
                                'Provider arriving in ~${job['eta_minutes']} min',
                                style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600),
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
                        if (job['status'] == 'completed') ...[
                          const SizedBox(height: 10),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          if (job['customer_rating'] == null) ...[
                            const Text('How was your service?',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SnowServColors.navy)),
                            const SizedBox(height: 6),
                            Row(
                              children: List.generate(5, (i) {
                                return GestureDetector(
                                  onTap: () => rateJob(
                                    job['id'].toString(),
                                    job['provider_id']?.toString(),
                                    i + 1,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Icon(
                                      Icons.star_border,
                                      color: Colors.amber,
                                      size: 32,
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ] else ...[
                            Row(
                              children: [
                                ...List.generate(5, (i) => Icon(
                                  i < (job['customer_rating'] as int)
                                      ? Icons.star
                                      : Icons.star_border,
                                  color: Colors.amber,
                                  size: 20,
                                )),
                                const SizedBox(width: 6),
                                Text('You rated this service',
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                              ],
                            ),
                          ],
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
              onTap: () => setState(() => orderingForSomeoneElse = !orderingForSomeoneElse),
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
                      onChanged: (val) => setState(() => orderingForSomeoneElse = val),
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
            const SizedBox(height: 16),
            serviceButton('sidewalk', 'Sidewalk Only', 50, Icons.directions_walk),
            serviceButton('driveway', 'Driveway Only', 100, Icons.directions_car),
            serviceButton('sidewalk_driveway', 'Sidewalk + Driveway', 125, Icons.home),

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
                  subtitle: const Text('+\$40', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
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
                                ? 'Surge Pricing — ${surgeMultiplier}x'
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
                                    '${surgeMultiplier > 1.0 ? ' — surge pricing active' : ''}',
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
        ),
      ),
      ),
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  final String clientSecret;
  final int amount;
  final String description;
  final Map<String, dynamic>? savedCard;
  final Future<void> Function(bool shouldSave, Map<String, dynamic>? cardDetails)? onSaveCard;
  const _PaymentSheet({
    required this.clientSecret,
    required this.amount,
    required this.description,
    this.savedCard,
    this.onSaveCard,
  });

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _nameController = TextEditingController();
  final _zipController = TextEditingController();
  bool _paying = false;
  String? _error;
  late bool _usingSavedCard;
  bool _saveCard = true;

  @override
  void initState() {
    super.initState();
    _usingSavedCard = widget.savedCard != null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _zipController.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    if (!_usingSavedCard) {
      if (_nameController.text.trim().isEmpty) {
        setState(() => _error = 'Please enter the name on your card.');
        return;
      }
      if (_zipController.text.trim().length < 5) {
        setState(() => _error = 'Please enter a valid billing ZIP code.');
        return;
      }
    }
    setState(() { _paying = true; _error = null; });
    try {
      if (_usingSavedCard && widget.savedCard != null) {
        await Stripe.instance.confirmPayment(
          paymentIntentClientSecret: widget.clientSecret,
          data: PaymentMethodParams.cardFromMethodId(
            paymentMethodData: PaymentMethodDataCardFromMethod(
              paymentMethodId: widget.savedCard!['id'],
            ),
          ),
        );
      } else {
        // Create PM first so we have the ID before confirming
        final pm = await Stripe.instance.createPaymentMethod(
          params: PaymentMethodParams.card(
            paymentMethodData: PaymentMethodData(
              billingDetails: BillingDetails(
                name: _nameController.text.trim(),
                address: Address(
                  postalCode: _zipController.text.trim(),
                  city: null, country: null, line1: null, line2: null, state: null,
                ),
              ),
            ),
          ),
        );
        await Stripe.instance.confirmPayment(
          paymentIntentClientSecret: widget.clientSecret,
          data: PaymentMethodParams.cardFromMethodId(
            paymentMethodData: PaymentMethodDataCardFromMethod(
              paymentMethodId: pm.id,
            ),
          ),
        );
        if (widget.onSaveCard != null) {
          final cardDetails = <String, dynamic>{
            'id': pm.id,
            'last4': pm.card.last4 ?? '',
            'brand': pm.card.brand ?? 'unknown',
            'exp_month': pm.card.expMonth ?? 0,
            'exp_year': pm.card.expYear ?? 0,
          };
          await widget.onSaveCard!(_saveCard, cardDetails);
        }
      }
      if (mounted) Navigator.pop(context, true);
    } on StripeException catch (e) {
      if (e.error.code == FailureCode.Canceled) {
        if (mounted) Navigator.pop(context, false);
      } else {
        setState(() => _error = e.error.localizedMessage ?? e.error.message ?? 'Payment failed.');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _paying = false);
    }
  }

  String _cardBrandIcon(String brand) {
    switch (brand.toLowerCase()) {
      case 'visa': return 'VISA';
      case 'mastercard': return 'MC';
      case 'amex': return 'AMEX';
      case 'discover': return 'DISC';
      default: return brand.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.savedCard;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Payment', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(widget.description, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 16),

          // Saved card section
          if (card != null && _usingSavedCard) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: SnowServColors.iceBlue, width: 1.5),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: SnowServColors.navy,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _cardBrandIcon(card['brand'] ?? ''),
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('••••  ••••  ••••  ${card['last4']}',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 1)),
                        Text('Exp ${card['exp_month']}/${card['exp_year']}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    ),
                  ),
                  const Icon(Icons.check_circle, color: SnowServColors.iceBlue, size: 20),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _usingSavedCard = false),
              child: const Text('Use a different card'),
            ),
          ] else ...[
            // New card entry form
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Name on Card',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 12),
            const Text('Card Number · MM/YY · CVC',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 6),
            CardField(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _zipController,
              decoration: const InputDecoration(
                labelText: 'Billing ZIP Code',
                prefixIcon: Icon(Icons.location_on_outlined),
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 5,
            ),
            if (card != null) ...[
              TextButton(
                onPressed: () => setState(() => _usingSavedCard = true),
                child: Text('Use saved card (••••${card['last4']})'),
              ),
            ] else ...[
              const SizedBox(height: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _saveCard,
                onChanged: (val) => setState(() => _saveCard = val ?? true),
                activeColor: SnowServColors.iceBlue,
                title: const Text('Save card for future payments',
                    style: TextStyle(fontSize: 13)),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ],

          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _paying ? null : _pay,
            child: _paying
                ? const SizedBox(height: 20, width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text('Pay \$${widget.amount}'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }
}
