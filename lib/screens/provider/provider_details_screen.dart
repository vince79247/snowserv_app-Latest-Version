import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';

final _supabase = Supabase.instance.client;

/// Lets an approved provider update their equipment (dispatch-matching), vehicle,
/// and insurance details on file (e.g. a new truck, a broken snowblower, a new
/// insurance carrier). Contact info (name/phone)
/// lives in EditProfileScreen; payouts (bank/ID) are handled by Stripe Connect
/// Express via the account menu. The driver's-license record is intentionally
/// NOT editable here — changing it should go through support / re-verification.
class ProviderDetailsScreen extends StatefulWidget {
  const ProviderDetailsScreen({super.key});

  @override
  State<ProviderDetailsScreen> createState() => _ProviderDetailsScreenState();
}

class _ProviderDetailsScreenState extends State<ProviderDetailsScreen> {
  final _picker = ImagePicker();

  final _makeCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _yearCtrl = TextEditingController();
  final _plateCtrl = TextEditingController();
  final _vinCtrl = TextEditingController();
  final _crewCtrl = TextEditingController();
  final _carrierCtrl = TextEditingController();
  final _policyCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();

  // Primary equipment — drives which jobs dispatch prefers you for (see the
  // Getting Started / Dispatching FAQ). Editable any time: gear breaks, gets
  // sold, or gets upgraded, so this shouldn't be locked to registration.
  String _equipment = 'shovel';
  bool _hasVehicle = false;
  bool _hasSalt = false;
  File? _newInsurancePhoto;
  bool _hasInsuranceOnFile = false;

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _makeCtrl, _modelCtrl, _yearCtrl, _plateCtrl, _vinCtrl,
      _crewCtrl, _carrierCtrl, _policyCtrl, _expiryCtrl,
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
              'equipment, has_vehicle, vehicle_make, vehicle_model, vehicle_year, vehicle_plate, vehicle_vin, crew_size, has_salt, insurance_carrier, insurance_policy, insurance_expiry, insurance_photo_url')
          .eq('user_id', id)
          .maybeSingle();
      if (p != null && mounted) {
        // Legacy providers (registered before this field) have equipment=null —
        // fall back to has_vehicle as the best guess (matches the dispatch
        // migration's own backfill), so the dropdown never shows a wrong pick.
        _equipment = (p['equipment'] as String?) ??
            (p['has_vehicle'] == true ? 'plow' : 'shovel');
        _hasVehicle = p['has_vehicle'] == true;
        _hasSalt = p['has_salt'] == true;
        _makeCtrl.text = (p['vehicle_make'] as String?) ?? '';
        _modelCtrl.text = (p['vehicle_model'] as String?) ?? '';
        _yearCtrl.text = '${p['vehicle_year'] ?? ''}';
        _plateCtrl.text = (p['vehicle_plate'] as String?) ?? '';
        _vinCtrl.text = (p['vehicle_vin'] as String?) ?? '';
        _crewCtrl.text = '${p['crew_size'] ?? 1}';
        _carrierCtrl.text = (p['insurance_carrier'] as String?) ?? '';
        _policyCtrl.text = (p['insurance_policy'] as String?) ?? '';
        _expiryCtrl.text = (p['insurance_expiry'] as String?) ?? '';
        _hasInsuranceOnFile =
            (p['insurance_photo_url'] as String?)?.isNotEmpty == true;
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickInsurancePhoto() async {
    final photo = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 80);
    if (photo != null && mounted) {
      setState(() => _newInsurancePhoto = File(photo.path));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final id = _supabase.auth.currentUser!.id;
      final update = <String, dynamic>{
        'equipment': _equipment,
        'has_vehicle': _hasVehicle,
        'crew_size': int.tryParse(_crewCtrl.text.trim()) ?? 1,
        'has_salt': _hasSalt,
        'insurance_carrier': _carrierCtrl.text.trim(),
        'insurance_policy': _policyCtrl.text.trim().toUpperCase(),
        'insurance_expiry': _expiryCtrl.text.trim(),
      };
      if (_hasVehicle) {
        update.addAll({
          'vehicle_make': _makeCtrl.text.trim(),
          'vehicle_model': _modelCtrl.text.trim(),
          'vehicle_year': _yearCtrl.text.trim(),
          'vehicle_plate': _plateCtrl.text.trim().toUpperCase(),
          'vehicle_vin': _vinCtrl.text.trim().toUpperCase(),
        });
      }
      // New insurance card → upload to the private bucket, store the PATH.
      if (_newInsurancePhoto != null) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final path = 'ins_${id}_$ts.jpg';
        await _supabase.storage
            .from('provider-documents')
            .upload(path, _newInsurancePhoto!);
        update['insurance_photo_url'] = path;
      }
      await _supabase.from('providers').update(update).eq('user_id', id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Details updated'),
            backgroundColor: SnowServColors.success));
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not save: $e'),
            backgroundColor: SnowServColors.danger));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(TextEditingController c, String label,
      {TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 10),
        child: Text(t,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: SnowServColors.navy)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Equipment, Vehicle & Insurance')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionTitle('Equipment'),
                  const Text(
                    'This is how we match you to jobs — keep it current if your '
                    'gear changes (breaks down, gets sold, gets upgraded). Pick '
                    'Snowblower or Plow truck to be sent driveway jobs.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _equipment,
                    decoration:
                        const InputDecoration(border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(
                          value: 'shovel',
                          child: Text('Shovel only (walkways & sidewalks)')),
                      DropdownMenuItem(
                          value: 'snowblower',
                          child:
                              Text('Snowblower (driveways & walkways)')),
                      DropdownMenuItem(
                          value: 'plow',
                          child: Text('Plow truck (driveways & lots)')),
                    ],
                    onChanged: (v) => setState(() {
                      _equipment = v!;
                      if (v == 'plow') _hasVehicle = true;
                    }),
                  ),
                  const Divider(height: 28),
                  _sectionTitle('Vehicle'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('I have a vehicle'),
                    value: _hasVehicle,
                    onChanged: (v) => setState(() => _hasVehicle = v),
                  ),
                  if (_hasVehicle) ...[
                    _field(_yearCtrl, 'Year',
                        keyboard: TextInputType.number),
                    _field(_makeCtrl, 'Make'),
                    _field(_modelCtrl, 'Model'),
                    _field(_plateCtrl, 'License plate'),
                    _field(_vinCtrl, 'VIN'),
                  ],
                  _field(_crewCtrl, 'Crew size',
                      keyboard: TextInputType.number),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('I have deicer'),
                    subtitle: const Text('Salt / ice melt supply'),
                    value: _hasSalt,
                    onChanged: (v) => setState(() => _hasSalt = v),
                  ),
                  const Divider(height: 28),
                  _sectionTitle('Insurance'),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _hasVehicle
                          ? '* Required — vehicle & plow providers must carry liability insurance.'
                          : 'Optional for shovel & snowblower providers — you can leave this blank. Add it only if you carry your own coverage.',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            _hasVehicle ? FontWeight.w600 : FontWeight.normal,
                        color: _hasVehicle
                            ? SnowServColors.danger
                            : Colors.black54,
                      ),
                    ),
                  ),
                  _field(_carrierCtrl, 'Insurance carrier'),
                  _field(_policyCtrl, 'Policy number'),
                  _field(_expiryCtrl, 'Expiry (MM/YYYY)'),
                  OutlinedButton.icon(
                    onPressed: _pickInsurancePhoto,
                    icon: const Icon(Icons.upload_file),
                    label: Text(_newInsurancePhoto != null
                        ? 'New card selected ✓'
                        : (_hasInsuranceOnFile
                            ? 'Replace insurance card photo'
                            : 'Upload insurance card photo')),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Save'),
                  ),
                ],
              ),
            ),
    );
  }
}
