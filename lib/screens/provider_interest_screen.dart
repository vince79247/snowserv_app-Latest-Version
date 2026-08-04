import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import 'faq_screen.dart';

// "Work with us" — a no-account interest form for people who might become
// providers. Deliberately NOT the full registration: a landscaper contacted in
// September isn't going to upload a license and insurance certificate on the
// spot, and asking them to is how you lose them. Name + one way to reach them is
// enough; the real registration happens later, in the app, when they're ready.
//
// Writes to public.provider_leads with the anon key. That table grants anon
// INSERT only — never SELECT — so this form can't be turned into a scraper for
// a list of local contractors' names, emails and phone numbers.

class ProviderInterestScreen extends StatefulWidget {
  const ProviderInterestScreen({super.key});

  @override
  State<ProviderInterestScreen> createState() => _ProviderInterestScreenState();
}

class _ProviderInterestScreenState extends State<ProviderInterestScreen> {
  final _supabase = Supabase.instance.client;
  final _name = TextEditingController();
  final _company = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _zip = TextEditingController();
  final _notes = TextEditingController();

  // Matches the equipment vocabulary dispatch actually cares about, so a lead's
  // answer maps straight onto providers.equipment at registration.
  static const _equipmentOptions = [
    'Shovel',
    'Snowblower',
    'Plow / truck',
    'More than one of these',
  ];
  String? _equipment;
  bool _submitting = false;
  bool _done = false;

  @override
  void dispose() {
    for (final c in [_name, _company, _phone, _email, _zip, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final hasContact =
        _phone.text.trim().isNotEmpty || _email.text.trim().isNotEmpty;
    if (_name.text.trim().isEmpty || !hasContact) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please add your name and either a phone or an email.'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    setState(() => _submitting = true);
    String? v(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      await _supabase.from('provider_leads').insert({
        'name': v(_name),
        'company': v(_company),
        'phone': v(_phone),
        'email': v(_email),
        'zip': v(_zip),
        'equipment': _equipment,
        'notes': v(_notes),
        'source': 'website form',
        'status': 'new',
      });
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not send: $e'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  Widget _field(TextEditingController c, String label,
          {String? hint, TextInputType? type, int lines = 1}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: type,
          maxLines: lines,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SnowServColors.frost,
      appBar: AppBar(
        title: const Text('Plow with SnowServ'),
        backgroundColor: SnowServColors.navy,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: _done ? _thanks() : _form(),
        ),
      ),
    );
  }

  Widget _thanks() => Column(
        children: [
          const SizedBox(height: 40),
          const Icon(Icons.check_circle, color: SnowServColors.success, size: 64),
          const SizedBox(height: 16),
          const Text('Thanks — we’ve got your details.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
          const SizedBox(height: 10),
          const Text(
            'We’ll reach out before the season starts to get you set up. '
            'Questions in the meantime? Email support@snowserv.app.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: SnowServColors.inkSoft),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back'),
          ),
        ],
      );

  Widget _form() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Earn money clearing snow',
              style: TextStyle(
                  fontSize: 23, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
          const SizedBox(height: 8),
          // The pitch, aimed squarely at landscapers: they already own the gear
          // and winter is their dead season. No fee, no customer-hunting.
          const Text(
            'We send you the jobs — you keep 75% of every one. No sign-up fee, '
            'nothing deducted for equipment or fuel, and you choose when you work.',
            style: TextStyle(fontSize: 14, height: 1.45, color: SnowServColors.ink),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SnowServColors.hairline),
            ),
            child: const Text(
              'Already run a landscaping or lawn-care business? Winter is dead '
              'time for most crews — this fills it with work you’re already '
              'equipped for.',
              style: TextStyle(fontSize: 13, color: SnowServColors.inkSoft, height: 1.4),
            ),
          ),
          const SizedBox(height: 20),
          _field(_name, 'Your name *'),
          _field(_company, 'Business name', hint: 'If you have one'),
          _field(_phone, 'Phone', type: TextInputType.phone),
          _field(_email, 'Email', type: TextInputType.emailAddress),
          _field(_zip, 'ZIP code you work in', type: TextInputType.number),
          DropdownButtonFormField<String>(
            initialValue: _equipment,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'What do you have?',
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.white,
            ),
            items: _equipmentOptions
                .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                .toList(),
            onChanged: (v) => setState(() => _equipment = v),
          ),
          const SizedBox(height: 12),
          _field(_notes, 'Anything else?', lines: 3,
              hint: 'Crew size, how many trucks, when you can start…'),
          const Text('* Name plus a phone or email is all we need to get in touch.',
              style: TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
              child: _submitting
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Send my details',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'This is just an introduction — no documents needed yet. '
            'Full sign-up (license, insurance, payout setup) comes later.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
          ),
          const SizedBox(height: 6),
          // Straight to the PROVIDER tab. The login screen's FAQ link opens on
          // the customer tab, so a contractor arriving from a recruiting ad
          // landed on answers written for homeowners and had to spot the tab.
          // This page IS the recruiting landing page — the questions a
          // contractor is weighing (pay, equipment, how dispatch picks) should
          // be one tap from it, or he asks by DM instead and nobody scales.
          TextButton.icon(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const FaqScreen(initialTab: 1))),
            icon: const Icon(Icons.help_outline, size: 16),
            label: const Text('Questions about pay, equipment or how jobs are sent?',
                style: TextStyle(fontSize: 12.5)),
          ),
        ],
      );
}
