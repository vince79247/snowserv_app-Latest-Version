import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import '../../theme.dart';
import '../../config/app_config.dart';
import 'provider_agreement_screen.dart';
import '../../utils/auth_actions.dart';
import '../../utils/legal.dart';


final supabase = Supabase.instance.client;

class ProviderRegistrationScreen extends StatefulWidget {
  const ProviderRegistrationScreen({super.key});

  @override
  State<ProviderRegistrationScreen> createState() => _ProviderRegistrationScreenState();
}

class _ProviderRegistrationScreenState extends State<ProviderRegistrationScreen> {
  final _pageController = PageController();
  int _currentPage = 0;
  bool _submitting = false;

  // Step 1 - Equipment
  String _providerType = 'solo';
  // Primary equipment — drives qualification-based dispatch. Defaults to the
  // conservative 'shovel' (won't over-promise driveway capability); providers
  // pick snowblower/plow to be matched to driveway jobs.
  String _equipment = 'shovel';
  int _crewSize = 1;
  // Derived, never toggled. "Do you own a truck?" and "do you plow with one?"
  // are different questions, and asking the first while enforcing the second is
  // what dragged shovel providers into vehicle details and insurance uploads.
  bool get _hasVehicle => _equipment == 'plow';
  final _vehicleMakeController = TextEditingController();
  final _vehicleModelController = TextEditingController();
  final _vehicleYearController = TextEditingController();
  final _vehiclePlateController = TextEditingController();
  bool _hasSalt = false;

  // Step 2 - Identity
  final _dlNumberController = TextEditingController();
  final _dlStateController = TextEditingController();
  File? _dlPhoto;

  // Step 3 - Insurance
  final _insuranceCarrierController = TextEditingController();
  final _insurancePolicyController = TextEditingController();
  final _insuranceExpiryController = TextEditingController();
  File? _insurancePhoto;
  bool _insuranceConfirmed = false;
  // Hand-tool (no-vehicle) providers: insurance is optional. They either say
  // they carry it (then we collect proof) or acknowledge they don't and are
  // personally responsible. Vehicle/plow providers always require insurance.
  bool _carriesInsurance = false;
  bool _noInsuranceAck = false;

  // Step 4 - Payouts: no bank/SSN/DOB collected here anymore. Stripe Connect
  // Express collects and verifies all of that (and files 1099s) via its own
  // hosted onboarding, launched from provider home AFTER approval. This step is
  // now just an explainer so nothing sensitive ever touches our database.

  // Step 5 - Agreement
  bool _termsAgreed = false;
  bool _agreementSigned = false;
  final _signatureController = TextEditingController();

  final _picker = ImagePicker();
  final _steps = ['Equipment', 'Identity', 'Insurance', 'Payouts', 'Agreement'];

  @override
  void dispose() {
    _pageController.dispose();
    _vehicleMakeController.dispose();
    _vehicleModelController.dispose();
    _vehicleYearController.dispose();
    _vehiclePlateController.dispose();
    _dlNumberController.dispose();
    _dlStateController.dispose();
    _insuranceCarrierController.dispose();
    _insurancePolicyController.dispose();
    _insuranceExpiryController.dispose();
    _signatureController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (!_validateCurrentPage()) return;
    if (_currentPage < 4) {
      _pageController.nextPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _currentPage++);
    } else {
      _submit();
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      _pageController.previousPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _currentPage--);
    }
  }

  bool _validateCurrentPage() {
    switch (_currentPage) {
      case 0:
        // Nothing blocks here any more. Truck details are optional at signup —
        // demanding them mid-registration means walking out to the driveway,
        // which is where people put the phone down and never come back. What is
        // missing is surfaced afterwards instead (see _outstandingItems).
        return true;
      case 1:
        if (_dlNumberController.text.trim().isEmpty ||
            _dlStateController.text.trim().isEmpty) {
          _showError('Please fill in all identity fields.');
          return false;
        }
        if (_dlPhoto == null) {
          _showError("Please upload a photo of your driver's license.");
          return false;
        }
        return true;
      case 2:
        // Insurance is REQUIRED for vehicle/plow providers, and required-if-
        // claimed for hand-tool providers who say they carry it. Hand-tool
        // providers with no insurance must instead acknowledge responsibility.
        if (_hasVehicle || _carriesInsurance) {
          if (_insuranceCarrierController.text.trim().isEmpty ||
              _insurancePolicyController.text.trim().isEmpty ||
              _insuranceExpiryController.text.trim().isEmpty) {
            _showError('Please fill in all insurance fields.');
            return false;
          }
          if (_insurancePhoto == null) {
            _showError('Please upload a photo of your insurance card.');
            return false;
          }
          if (_hasVehicle && !_insuranceConfirmed) {
            _showError('Please confirm your general liability insurance coverage.');
            return false;
          }
          return true;
        }
        if (!_noInsuranceAck) {
          _showError(
              'Please acknowledge responsibility, or switch on "I carry insurance" and add your policy.');
          return false;
        }
        return true;
      case 3:
        // Payouts step is now an explainer — Stripe collects bank/SSN later.
        return true;
      case 4:
        if (!_termsAgreed) {
          _showError('Please agree to the Terms of Service to continue.');
          return false;
        }
        if (_signatureController.text.trim().length < 3) {
          _showError('Type your full legal name to sign the Provider Service Agreement.');
          return false;
        }
        if (!_agreementSigned) {
          _showError('Please read and sign the Provider Service Agreement to continue.');
          return false;
        }
        return true;
      default:
        return true;
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(message), backgroundColor: SnowServColors.danger),
    );
  }

  Future<void> _pickPhoto(bool isDL) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from Gallery'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final photo = await _picker.pickImage(source: source, imageQuality: 80);
    if (photo != null && mounted) {
      setState(() {
        if (isDL) {
          _dlPhoto = File(photo.path);
        } else {
          _insurancePhoto = File(photo.path);
        }
      });
    }
  }

  Future<String> _uploadPhoto(File file, String filename) async {
    await supabase.storage.from('provider-documents').upload(filename, file);
    // Store the object PATH, not a public URL — the bucket is private. The admin
    // views documents through a short-lived signed URL minted by the password-
    // gated admin-doc-url function.
    return filename;
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final userId = supabase.auth.currentUser!.id;
      final ts = DateTime.now().millisecondsSinceEpoch;

      String? dlUrl;
      String? insuranceUrl;

      if (_dlPhoto != null) {
        dlUrl = await _uploadPhoto(_dlPhoto!, 'dl_${userId}_$ts.jpg');
      }
      if (_insurancePhoto != null) {
        insuranceUrl = await _uploadPhoto(_insurancePhoto!, 'ins_${userId}_$ts.jpg');
      }

      await supabase.from('providers').update({
        'provider_type': _providerType,
        'equipment': _equipment,
        'crew_size': _crewSize,
        'has_vehicle': _hasVehicle,
        'has_salt': _hasSalt,
        if (_hasVehicle) ...{
          'vehicle_make': _vehicleMakeController.text.trim(),
          'vehicle_model': _vehicleModelController.text.trim(),
          'vehicle_year': _vehicleYearController.text.trim(),
          'vehicle_plate': _vehiclePlateController.text.trim().toUpperCase(),
        },
        'dl_number': _dlNumberController.text.trim().toUpperCase(),
        'dl_state': _dlStateController.text.trim().toUpperCase(),
        if (dlUrl != null) 'dl_photo_url': dlUrl,
        // Insurance: vehicle providers always; hand-tool providers only if they
        // said they carry it. Otherwise record the no-insurance acknowledgment.
        'has_insurance': _hasVehicle || _carriesInsurance,
        if (_hasVehicle || _carriesInsurance) ...{
          'insurance_carrier': _insuranceCarrierController.text.trim(),
          'insurance_policy': _insurancePolicyController.text.trim().toUpperCase(),
          'insurance_expiry': _insuranceExpiryController.text.trim(),
        },
        if (insuranceUrl != null) 'insurance_photo_url': insuranceUrl,
        if (!_hasVehicle && !_carriesInsurance)
          'insurance_ack_at': DateTime.now().toUtc().toIso8601String(),
        'terms_agreed': true,
        'service_agreement_signed_at': DateTime.now().toUtc().toIso8601String(),
        'service_agreement_name': _signatureController.text.trim(),
        'service_agreement_version': kProviderAgreementVersion,
        'registration_status': 'pending_review',
      }).eq('user_id', userId);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const ProviderPendingScreen()),
        );
      }
    } catch (e) {
      if (mounted) _showError('Submission failed: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SnowServColors.navy,
      appBar: AppBar(
        backgroundColor: SnowServColors.navy,
        elevation: 0,
        title: const Text('Provider Registration',
            style: TextStyle(color: Colors.white)),
        leading: _currentPage > 0
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _prevPage,
              )
            : null,
        actions: [
          TextButton(
            onPressed: () => signOutSafely(context),
            child: const Text('Log Out', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: List.generate(_steps.length, (i) {
                final isActive = i == _currentPage;
                final isDone = i < _currentPage;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i < _steps.length - 1 ? 4 : 0),
                    child: Column(
                      children: [
                        Container(
                          height: 4,
                          decoration: BoxDecoration(
                            color: isDone || isActive
                                ? SnowServColors.iceBlue
                                : Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _steps[i],
                          style: TextStyle(
                            fontSize: 10,
                            color: isActive
                                ? SnowServColors.iceBlue
                                : isDone
                                    ? Colors.white70
                                    : Colors.white30,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildEquipmentPage(),
                _buildIdentityPage(),
                _buildInsurancePage(),
                _buildBankingPage(),
                _buildAgreementPage(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting ? null : _nextPage,
                style: ElevatedButton.styleFrom(
                  backgroundColor: SnowServColors.iceBlue,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(
                        _currentPage == 4 ? 'Submit Application' : 'Continue',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, String? subtitle, required Widget child}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      // Material, not a Container with a BoxDecoration. ListTile and
      // SwitchListTile paint their ink splashes on the nearest Material
      // ancestor, so a coloured DecoratedBox in between swallows every tap
      // ripple on this screen — the toggles looked dead when touched. Flutter
      // reports this, but only at runtime, which is why a widget test found it
      // and `flutter analyze` never could.
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: SnowServColors.navy)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle,
                  style: const TextStyle(color: SnowServColors.inkSoft, fontSize: 13)),
            ],
              const SizedBox(height: 20),
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEquipmentPage() {
    return _card(
      title: 'Equipment & Service Type',
      subtitle: 'Tell us about your setup so we can match you with the right jobs.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: SnowServColors.success.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: SnowServColors.success.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified_outlined,
                    color: SnowServColors.success, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  // Provider's share tracks the live commission (admin-editable),
                  // so this pitch never drifts from what they actually earn.
                  child: Text(
                      'No sign-up fees. No monthly fees. No contract — you keep '
                      '${(100 - AppConfig.commissionPct).round()}% of every job.',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SnowServColors.ink)),
                ),
              ],
            ),
          ),
          const Text('Provider Type', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          // isExpanded, like the equipment field below: without it the button
          // sizes to its content and a long label runs past the border instead
          // of ellipsising inside it. Shorter labels here so it hasn't bitten
          // yet, but the defect is the same.
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: _providerType,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: 'solo', child: Text('Solo (just me)')),
              DropdownMenuItem(value: 'small_crew', child: Text('Small crew (2–3 people)')),
              DropdownMenuItem(value: 'large_crew', child: Text('Large crew (4+ people)')),
            ],
            onChanged: (val) => setState(() {
              _providerType = val!;
              _crewSize = val == 'solo' ? 1 : val == 'small_crew' ? 2 : 4;
            }),
          ),
          const SizedBox(height: 16),
          const Text('Primary equipment',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            'This is how we match you to jobs. Pick Snowblower or Plow truck to '
            'be sent driveway jobs; Shovel only gets walkway & sidewalk jobs.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          const SizedBox(height: 8),
          // Cards, not a dropdown. All three choices are visible at once, the
          // tap targets are thumb-sized, and it sits consistently beside the
          // toggles below instead of looking like a different kind of control.
          _equipmentCard('shovel', Icons.cleaning_services, 'Shovel only',
              'Walkways and sidewalks'),
          _equipmentCard('snowblower', Icons.ac_unit, 'Snowblower',
              'Driveways and walkways'),
          _equipmentCard('plow', Icons.local_shipping, 'Plow truck',
              'Driveways and larger jobs'),
          const SizedBox(height: 16),
          const Text('Crew Size', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                onPressed: _crewSize > 1 ? () => setState(() => _crewSize--) : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              Text('$_crewSize',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              IconButton(
                onPressed: () => setState(() => _crewSize++),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          ),
          // The vehicle question used to be a separate toggle that answered
          // itself — picking "Plow truck" silently switched it on. Worse, its
          // label asked "do you own a truck?" while its requirements assumed
          // "do you plow commercially?", so a shovel provider with a pickup got
          // dragged into vehicle details and an insurance card he didn't need.
          // It's now derived from the equipment choice above.
          if (_hasVehicle) ...[
            const Divider(height: 24),
            const Text('Your truck',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'Optional — you can add these later. We only use them to identify '
              'your truck on site.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _vehicleMakeController,
                    decoration: const InputDecoration(
                        labelText: 'Make', border: OutlineInputBorder()),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _vehicleModelController,
                    decoration: const InputDecoration(
                        labelText: 'Model', border: OutlineInputBorder()),
                    textCapitalization: TextCapitalization.words,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 78,
                  child: TextField(
                    controller: _vehicleYearController,
                    decoration: const InputDecoration(
                        labelText: 'Year',
                        border: OutlineInputBorder(),
                        counterText: ''),
                    keyboardType: TextInputType.number,
                    maxLength: 4,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // VIN removed deliberately. It was the heaviest field in the whole
            // form — 17 characters you have to walk out to the truck to read —
            // and it bought us nothing: we don't insure the vehicle, the
            // contractor's own insurer does, and Stripe handles identity. Plate
            // plus make/model/year identifies a truck on site perfectly well.
            TextField(
              controller: _vehiclePlateController,
              decoration: const InputDecoration(
                  labelText: 'License Plate', border: OutlineInputBorder()),
              textCapitalization: TextCapitalization.characters,
            ),
          ],
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('I have deicer',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Bag, spreader, or any supply of ice melt / salt',
                style: TextStyle(fontSize: 12)),
            value: _hasSalt,
            activeColor: SnowServColors.iceBlue,
            onChanged: (val) => setState(() => _hasSalt = val),
          ),
        ],
      ),
    );
  }

  // One tappable row per equipment type. Selecting "Plow truck" is also what
  // reveals the truck fields, so the choice and its consequence sit together
  // instead of being split across a dropdown and a switch that moved itself.
  Widget _equipmentCard(
      String value, IconData icon, String title, String subtitle) {
    final selected = _equipment == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _equipment = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? SnowServColors.iceBlue.withValues(alpha: 0.08)
                : Colors.transparent,
            border: Border.all(
              color: selected ? SnowServColors.iceBlue : SnowServColors.glacier,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? SnowServColors.iceBlue : Colors.black54),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight:
                                selected ? FontWeight.bold : FontWeight.w600,
                            fontSize: 15)),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54)),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? SnowServColors.iceBlue : SnowServColors.glacier,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIdentityPage() {
    return _card(
      title: 'Identity Verification',
      subtitle: 'Required to confirm your identity before receiving jobs.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _dlNumberController,
                  decoration: const InputDecoration(
                    labelText: "Driver's License #",
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.characters,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _dlStateController,
                  decoration: const InputDecoration(
                    labelText: 'State',
                    border: OutlineInputBorder(),
                    counterText: '',
                  ),
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text("Driver's License Photo",
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _photoUpload(
            photo: _dlPhoto,
            label: "Upload Driver's License",
            onTap: () => _pickPhoto(true),
          ),
        ],
      ),
    );
  }

  // Carrier / policy / expiry / card-photo fields — shared by the two paths
  // that actually collect insurance (vehicle providers, and hand-tool providers
  // who say they carry it).
  Widget _insuranceFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _insuranceCarrierController,
          decoration: const InputDecoration(
            labelText: 'Insurance Carrier',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _insurancePolicyController,
          decoration: const InputDecoration(
            labelText: 'Policy Number',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.characters,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _insuranceExpiryController,
          decoration: const InputDecoration(
            labelText: 'Expiration Date (MM/DD/YYYY)',
            prefixIcon: Icon(Icons.calendar_today_outlined),
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.datetime,
        ),
        const SizedBox(height: 20),
        const Text('Insurance Card Photo',
            style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        _photoUpload(
          photo: _insurancePhoto,
          label: 'Upload Insurance Card',
          onTap: () => _pickPhoto(false),
        ),
      ],
    );
  }

  Widget _buildInsurancePage() {
    // Vehicle / plow providers: insurance is required (they can cause serious
    // property damage), so keep the full required form + the coverage checkbox.
    if (_hasVehicle) {
      return _card(
        title: 'Insurance',
        subtitle:
            'Because you plow with a vehicle, valid liability insurance is required.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _insuranceFields(),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _insuranceConfirmed,
              onChanged: (val) => setState(() => _insuranceConfirmed = val ?? false),
              activeColor: SnowServColors.iceBlue,
              title: const Text(
                'I confirm I carry at least \$1,000,000 in general liability insurance.',
                style: TextStyle(fontSize: 13),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      );
    }

    // Hand-tool providers: insurance is optional. They either add a policy or
    // acknowledge they carry none and are personally responsible.
    return _card(
      title: 'Insurance',
      subtitle: 'Optional for hand-shoveling — but recommended.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('I carry liability insurance',
                style: TextStyle(fontWeight: FontWeight.w600)),
            value: _carriesInsurance,
            activeColor: SnowServColors.iceBlue,
            onChanged: (val) => setState(() => _carriesInsurance = val),
          ),
          if (_carriesInsurance) ...[
            const SizedBox(height: 8),
            _insuranceFields(),
          ] else ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SnowServColors.iceBlue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: SnowServColors.iceBlue.withValues(alpha: 0.25)),
              ),
              child: const Text(
                'SnowServ does not provide insurance for you. Carrying your own '
                'liability coverage is strongly recommended.',
                style: TextStyle(fontSize: 12, color: SnowServColors.iceBlue),
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _noInsuranceAck,
              onChanged: (val) => setState(() => _noInsuranceAck = val ?? false),
              activeColor: SnowServColors.iceBlue,
              title: const Text(
                'I understand I am personally responsible for any property damage '
                'or injury that arises from my work, as described in the Provider '
                'Service Agreement.',
                style: TextStyle(fontSize: 13),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBankingPage() {
    return _card(
      title: 'Getting Paid',
      subtitle: 'How payouts work — nothing to enter here.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SnowServColors.iceBlue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: SnowServColors.iceBlue.withValues(alpha: 0.25)),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: SnowServColors.iceBlue),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'SnowServ never collects or stores your bank details or Social '
                    'Security number. Our payments partner, Stripe, handles that '
                    'directly and securely.',
                    style: TextStyle(fontSize: 12, color: SnowServColors.iceBlue),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "After your application is approved, you'll see a “Set up payouts” "
            'button on your home screen. It opens Stripe’s secure page, where you '
            'add your bank account and verify your identity. Stripe also issues '
            'your year-end 1099 tax form.',
            style: TextStyle(fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 12),
          const Text(
            'You can finish your application now and set up payouts once approved '
            '— you just need it done before your first payout.',
            style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildAgreementPage() {
    return _card(
      title: 'Terms of Service',
      subtitle: 'Please read and agree before submitting your application.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _legalLinkTile(
            icon: Icons.description_outlined,
            label: 'Read Terms of Service',
            url: termsOfServiceUrl,
          ),
          const SizedBox(height: 10),
          _legalLinkTile(
            icon: Icons.privacy_tip_outlined,
            label: 'Read Privacy Policy',
            url: privacyPolicyUrl,
          ),
          const SizedBox(height: 16),
          const SizedBox(height: 16),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _termsAgreed,
            onChanged: (val) => setState(() => _termsAgreed = val ?? false),
            activeColor: SnowServColors.iceBlue,
            title: const Text(
              'I have read and agree to the SnowServ Terms of Service.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 12),
          const Text('Provider Service Agreement',
              style: TextStyle(fontWeight: FontWeight.bold, color: SnowServColors.navy)),
          const SizedBox(height: 4),
          const Text(
            'Covers non-circumvention (no taking SnowServ customers off-platform). '
            'You must read and sign it to accept jobs.',
            style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ProviderAgreementScreen())),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: SnowServColors.iceBlue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: SnowServColors.iceBlue.withValues(alpha: 0.25)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.assignment_outlined, color: SnowServColors.iceBlue, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                      child: Text('Read Provider Service Agreement',
                          style: TextStyle(color: SnowServColors.iceBlue, fontWeight: FontWeight.w600))),
                  Icon(Icons.chevron_right, color: SnowServColors.iceBlue, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _signatureController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Type your full legal name to sign',
              prefixIcon: Icon(Icons.draw_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _agreementSigned,
            onChanged: (val) => setState(() => _agreementSigned = val ?? false),
            activeColor: SnowServColors.iceBlue,
            title: const Text(
              'I have read and agree to the Provider Service Agreement, and my typed name '
              'above is my electronic signature.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
    );
  }

  Widget _legalLinkTile({required IconData icon, required String label, required String url}) {
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: SnowServColors.iceBlue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: SnowServColors.iceBlue.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Icon(icon, color: SnowServColors.iceBlue, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: const TextStyle(color: SnowServColors.iceBlue, fontWeight: FontWeight.w600))),
            const Icon(Icons.open_in_new, color: SnowServColors.iceBlue, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _photoUpload({required File? photo, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: SnowServColors.surfaceSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: photo != null ? SnowServColors.iceBlue : SnowServColors.hairline,
            width: photo != null ? 2 : 1,
          ),
        ),
        child: photo != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: Image.file(photo, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: SnowServColors.iceBlue,
                      child: const Icon(Icons.check, size: 14, color: Colors.white),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.upload_file, size: 32, color: SnowServColors.glacier),
                  const SizedBox(height: 8),
                  Text(label, style: const TextStyle(color: SnowServColors.ink, fontSize: 13, fontWeight: FontWeight.w600)),
                  const Text('Tap to take photo or upload from gallery',
                      style: TextStyle(color: SnowServColors.inkSoft, fontSize: 11)),
                ],
              ),
      ),
    );
  }
}

class ProviderPendingScreen extends StatelessWidget {
  final bool isRejected;
  const ProviderPendingScreen({super.key, this.isRejected = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SnowServColors.navy,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isRejected ? Icons.cancel_outlined : Icons.hourglass_top,
                size: 72,
                color: isRejected ? Colors.redAccent : SnowServColors.iceBlue,
              ),
              const SizedBox(height: 24),
              Text(
                isRejected ? 'Application Not Approved' : 'Application Submitted!',
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                isRejected
                    ? 'Unfortunately your application was not approved at this time. Please contact support for more information.'
                    : "Your application is under review. We'll notify you once you're approved to start accepting jobs.",
                style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
                textAlign: TextAlign.center,
              ),
              if (!isRejected) ...[
                const SizedBox(height: 8),
                const Text(
                  'Review typically takes 1–2 business days.',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => signOutSafely(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white30),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Log Out'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
