import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_stripe/flutter_stripe.dart' hide Card;
import 'dart:convert';
import 'dart:io';
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
  bool orderingForSomeoneElse = false;
  final _otherAddressController = TextEditingController();
  final _otherCityController = TextEditingController();
  final _otherStateController = TextEditingController();
  final _otherZipController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadMyJobs();
    loadAddress();
    loadSurge();
    subscribeToJobs();
  }

  @override
  void dispose() {
    _jobsChannel?.unsubscribe();
    _otherAddressController.dispose();
    _otherCityController.dispose();
    _otherStateController.dispose();
    _otherZipController.dispose();
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
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'customer_id',
        value: userId,
      ),
      callback: (payload) => loadMyJobs(),
    ).subscribe();
  }

  Future<void> loadMyJobs() async {
    try {
      final data = await supabase
          .from('jobs')
          .select()
          .eq('customer_id', supabase.auth.currentUser!.id)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() => myJobs = List<Map<String, dynamic>>.from(data));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error loading jobs: $e')));
      }
    }
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

  Future<void> createJob() async {
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
        body: {'amount_cents': amountCents, 'job_description': description},
      );
      final clientSecret = intentResponse.data['client_secret'] as String?;
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
      }).select('id').single();

      supabase.functions.invoke('notify-providers', body: {'job_id': result['id']});
      loadMyJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment successful! Job requested.')),
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
        content: const Text('Are you sure you want to cancel this service request?'),
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
      await supabase.from('jobs').delete().eq('id', jobId);
      loadMyJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Request cancelled.')),
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
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Service History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CustomerJobHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () { loadMyJobs(); loadAddress(); loadSurge(); },
          ),
          TextButton(
            onPressed: () => supabase.auth.signOut(),
            child: const Text('Log Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (myJobs.isNotEmpty) ...[
              const Text('Your Jobs',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
              const SizedBox(height: 8),
              ...myJobs.map((job) {
                final canCancel = job['status'] == 'requested';
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
                                    '\$${job['final_price'] ?? job['base_price']}',
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
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
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
  const _PaymentSheet({required this.clientSecret, required this.amount, required this.description});

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _nameController = TextEditingController();
  final _zipController = TextEditingController();
  bool _paying = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _zipController.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Please enter the name on your card.');
      return;
    }
    if (_zipController.text.trim().length < 5) {
      setState(() => _error = 'Please enter a valid billing ZIP code.');
      return;
    }
    setState(() { _paying = true; _error = null; });
    try {
      await Stripe.instance.confirmPayment(
        paymentIntentClientSecret: widget.clientSecret,
        data: PaymentMethodParams.card(
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

  @override
  Widget build(BuildContext context) {
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
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _paying ? null : _pay,
            child: _paying
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
