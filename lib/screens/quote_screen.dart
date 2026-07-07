import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../utils/geo.dart';
import '../utils/geocode.dart';

final _supabase = Supabase.instance.client;

// Instant quote before signup. Reads prices from the public service_areas table
// (readable with the anon key), so a prospective customer can see what SnowServ
// costs in their area — or join the waitlist if their ZIP isn't served yet.
// Pops `true` when the user taps "Sign up to book" so the auth screen can switch
// to the signup form.
class QuoteScreen extends StatefulWidget {
  const QuoteScreen({super.key});

  @override
  State<QuoteScreen> createState() => _QuoteScreenState();
}

class _QuoteScreenState extends State<QuoteScreen> {
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _zipCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();

  bool _loading = false;
  bool _searched = false;
  Map<String, dynamic>? _area; // matched area; null after a search = not served

  @override
  void dispose() {
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _zipCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _getQuote() async {
    final zip = _zipCtrl.text.trim();
    if (_addressCtrl.text.trim().isEmpty ||
        _cityCtrl.text.trim().isEmpty ||
        _stateCtrl.text.trim().isEmpty ||
        zip.length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your full address and ZIP.')),
      );
      return;
    }
    setState(() => _loading = true);
    try {
      // Geocode the address, then test the point against each active zone's
      // polygon (falling back to its ZIP list for zones not yet drawn).
      final geo = await geocodeAddress({
        'address_line': _addressCtrl.text.trim(),
        'city': _cityCtrl.text.trim(),
        'state': _stateCtrl.text.trim(),
        'zip': zip,
      });
      final rows = await _supabase
          .from('service_areas')
          .select()
          .eq('is_active', true);
      final zones = (rows as List).map((r) => Map<String, dynamic>.from(r)).toList();
      final match = matchZone(geo?['lat'], geo?['lng'], zip: zip, zones: zones);
      if (!mounted) return;
      setState(() {
        _area = match;
        _searched = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _area = null;
        _searched = true;
        _loading = false;
      });
    }
  }

  Future<void> _joinWaitlist() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid email so we can notify you.')),
      );
      return;
    }
    try {
      await _supabase.from('waitlist').insert({
        'email': email,
        'zip': _zipCtrl.text.trim(),
        'address':
            '${_addressCtrl.text.trim()}, ${_cityCtrl.text.trim()}, ${_stateCtrl.text.trim()} ${_zipCtrl.text.trim()}',
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Get an Instant Quote')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('See your price before you sign up',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
          const SizedBox(height: 4),
          const Text("Enter your address and we'll show what SnowServ costs in your area.",
              style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.green.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.verified_outlined, color: Colors.green.shade700, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('No contracts. No monthly fees. No hidden fees — just pay per job.',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _addressCtrl,
            decoration: const InputDecoration(labelText: 'Street address', filled: true, fillColor: Colors.white),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _cityCtrl,
                  decoration: const InputDecoration(labelText: 'City', filled: true, fillColor: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _stateCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'State', filled: true, fillColor: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _zipCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'ZIP', filled: true, fillColor: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _loading ? null : _getQuote,
            child: _loading
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('See My Price'),
          ),
          if (_searched) ...[
            const SizedBox(height: 20),
            if (_area != null) _buildQuoteResult() else _buildNotAvailable(),
          ],
        ],
      ),
    );
  }

  Widget _buildQuoteResult() {
    final a = _area!;
    int p(String k) => (a[k] as num?)?.round() ?? 0;
    Widget row(String label, int price) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 15)),
              Text('\$$price', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.green)),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: SnowServColors.glacier),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text('We serve ${a['name']}!',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: SnowServColors.navy)),
              ),
            ],
          ),
          const Divider(height: 20),
          row('Sidewalk only', p('price_sidewalk')),
          row('Driveway only', p('price_driveway')),
          row('Sidewalk + Driveway', p('price_both')),
          row('Salting add-on', p('price_salting')),
          const SizedBox(height: 8),
          const Text('Prices may be higher during heavy snow (storm pricing).',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Sign up to book'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotAvailable() {
    return Container(
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
            "SnowServ isn't in your area yet — but we're expanding. Leave your email and "
            "we'll notify you the moment we arrive.",
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Your email', filled: true, fillColor: Colors.white),
          ),
          const SizedBox(height: 8),
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
}
