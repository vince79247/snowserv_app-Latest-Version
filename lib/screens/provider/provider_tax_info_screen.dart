import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';

final _supabase = Supabase.instance.client;

/// Collects the W-9-style tax information SnowServ needs to issue a year-end
/// 1099-NEC to the provider (via Stripe Connect). Sensitive (SSN/EIN) — visible
/// only to the provider and admins. The SSN column already exists (captured at
/// registration); this screen fills in the rest and lets it be corrected.
class ProviderTaxInfoScreen extends StatefulWidget {
  const ProviderTaxInfoScreen({super.key});

  @override
  State<ProviderTaxInfoScreen> createState() => _ProviderTaxInfoScreenState();
}

// value stored in DB -> label shown, and whether it uses SSN (vs EIN).
const _classifications = <String, ({String label, bool usesSsn})>{
  'individual': (label: 'Individual / Sole proprietor', usesSsn: true),
  'single_member_llc': (label: 'Single-member LLC', usesSsn: true),
  'partnership': (label: 'Partnership', usesSsn: false),
  's_corp': (label: 'S corporation', usesSsn: false),
  'c_corp': (label: 'C corporation', usesSsn: false),
};

class _ProviderTaxInfoScreenState extends State<ProviderTaxInfoScreen> {
  final _legalName = TextEditingController();
  final _businessName = TextEditingController();
  final _ssn = TextEditingController();
  final _ein = TextEditingController();
  final _addr = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _zip = TextEditingController();

  String _classification = 'individual';
  bool _consent = false;
  bool _loading = true;
  bool _saving = false;

  bool get _usesSsn => _classifications[_classification]!.usesSsn;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _legalName, _businessName, _ssn, _ein, _addr, _city, _state, _zip
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final id = _supabase.auth.currentUser!.id;
      final p = await _supabase
          .from('providers')
          .select(
              'ssn, tax_legal_name, tax_business_name, tax_classification, tax_ein, tax_address_line, tax_city, tax_state, tax_zip, tax_efile_consent')
          .eq('user_id', id)
          .maybeSingle();
      if (p != null && mounted) {
        _legalName.text = (p['tax_legal_name'] as String?) ?? '';
        _businessName.text = (p['tax_business_name'] as String?) ?? '';
        _classification =
            (p['tax_classification'] as String?) ?? 'individual';
        if (!_classifications.containsKey(_classification)) {
          _classification = 'individual';
        }
        _ssn.text = (p['ssn'] as String?) ?? '';
        _ein.text = (p['tax_ein'] as String?) ?? '';
        _addr.text = (p['tax_address_line'] as String?) ?? '';
        _city.text = (p['tax_city'] as String?) ?? '';
        _state.text = (p['tax_state'] as String?) ?? '';
        _zip.text = (p['tax_zip'] as String?) ?? '';
        _consent = p['tax_efile_consent'] == true;
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    // Light validation of the relevant tax ID.
    final id9 = _usesSsn
        ? _ssn.text.replaceAll(RegExp(r'[^0-9]'), '')
        : _ein.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (_legalName.text.trim().isEmpty) {
      return _snack('Enter your legal name.');
    }
    if (id9.length != 9) {
      return _snack(_usesSsn
          ? 'SSN must be 9 digits.'
          : 'EIN must be 9 digits (e.g. 12-3456789).');
    }

    setState(() => _saving = true);
    try {
      final id = _supabase.auth.currentUser!.id;
      final update = <String, dynamic>{
        'tax_legal_name': _legalName.text.trim(),
        'tax_business_name': _businessName.text.trim(),
        'tax_classification': _classification,
        'tax_address_line': _addr.text.trim(),
        'tax_city': _city.text.trim(),
        'tax_state': _state.text.trim().toUpperCase(),
        'tax_zip': _zip.text.trim(),
        'tax_efile_consent': _consent,
        'tax_efile_consent_at':
            _consent ? DateTime.now().toIso8601String() : null,
      };
      if (_usesSsn) {
        update['ssn'] = id9;
        update['tax_ein'] = null;
      } else {
        update['tax_ein'] = id9;
      }
      await _supabase.from('providers').update(update).eq('user_id', id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Tax info saved'),
            backgroundColor: SnowServColors.success));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) _snack('Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tax Info (for 1099)')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: SnowServColors.frost,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: SnowServColors.hairline),
                    ),
                    child: const Text(
                      'We use this to send you a 1099-NEC form at tax time for '
                      'what you earned through SnowServ. Your information is '
                      'kept secure and is never shown to customers.',
                      style: TextStyle(
                          fontSize: 13, color: SnowServColors.inkSoft),
                    ),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _legalName,
                    decoration: const InputDecoration(
                        labelText: 'Full legal name',
                        prefixIcon: Icon(Icons.badge_outlined)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _businessName,
                    decoration: const InputDecoration(
                        labelText: 'Business name (if any)',
                        prefixIcon: Icon(Icons.business_outlined)),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _classification,
                    decoration: const InputDecoration(
                        labelText: 'Tax classification',
                        prefixIcon: Icon(Icons.account_balance_outlined)),
                    items: [
                      for (final e in _classifications.entries)
                        DropdownMenuItem(
                            value: e.key, child: Text(e.value.label)),
                    ],
                    onChanged: (v) =>
                        setState(() => _classification = v ?? 'individual'),
                  ),
                  const SizedBox(height: 12),
                  // Tax ID: SSN for individuals / single-member LLC, else EIN.
                  if (_usesSsn)
                    TextField(
                      controller: _ssn,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      decoration: const InputDecoration(
                          labelText: 'Social Security Number (SSN)',
                          hintText: '9 digits',
                          prefixIcon: Icon(Icons.lock_outline)),
                    )
                  else
                    TextField(
                      controller: _ein,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      decoration: const InputDecoration(
                          labelText: 'Employer ID Number (EIN)',
                          hintText: '9 digits',
                          prefixIcon: Icon(Icons.lock_outline)),
                    ),
                  const Divider(height: 32),
                  const Text('Mailing address',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: SnowServColors.navy)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _addr,
                    decoration:
                        const InputDecoration(labelText: 'Street address'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _city,
                    decoration: const InputDecoration(labelText: 'City'),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _state,
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(2)
                        ],
                        decoration:
                            const InputDecoration(labelText: 'State (e.g. NY)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _zip,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'ZIP code'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _consent,
                    onChanged: (v) => setState(() => _consent = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Receive my 1099 electronically',
                        style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                        'Get your tax form by email instead of paper mail.',
                        style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Save tax info'),
                  ),
                ],
              ),
            ),
    );
  }
}
