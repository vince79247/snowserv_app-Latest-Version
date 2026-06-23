import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../theme.dart';

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
  int _crewSize = 1;
  bool _hasVehicle = false;
  final _vehicleMakeController = TextEditingController();
  final _vehicleModelController = TextEditingController();
  final _vehicleYearController = TextEditingController();
  final _vehicleVinController = TextEditingController();
  final _vehiclePlateController = TextEditingController();
  bool _hasSalt = false;

  // Step 2 - Identity
  final _dobController = TextEditingController();
  final _dlNumberController = TextEditingController();
  final _dlStateController = TextEditingController();
  File? _dlPhoto;

  // Step 3 - Insurance
  final _insuranceCarrierController = TextEditingController();
  final _insurancePolicyController = TextEditingController();
  final _insuranceExpiryController = TextEditingController();
  File? _insurancePhoto;
  bool _insuranceConfirmed = false;

  // Step 4 - Banking
  final _routingController = TextEditingController();
  final _accountController = TextEditingController();

  // Step 5 - Agreement
  bool _termsAgreed = false;

  final _picker = ImagePicker();
  final _steps = ['Equipment', 'Identity', 'Insurance', 'Banking', 'Agreement'];

  @override
  void dispose() {
    _pageController.dispose();
    _vehicleMakeController.dispose();
    _vehicleModelController.dispose();
    _vehicleYearController.dispose();
    _vehicleVinController.dispose();
    _vehiclePlateController.dispose();
    _dobController.dispose();
    _dlNumberController.dispose();
    _dlStateController.dispose();
    _insuranceCarrierController.dispose();
    _insurancePolicyController.dispose();
    _insuranceExpiryController.dispose();
    _routingController.dispose();
    _accountController.dispose();
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
        if (_hasVehicle &&
            (_vehicleMakeController.text.trim().isEmpty ||
                _vehicleModelController.text.trim().isEmpty ||
                _vehicleYearController.text.trim().isEmpty ||
                _vehicleVinController.text.trim().isEmpty ||
                _vehiclePlateController.text.trim().isEmpty)) {
          _showError('Please fill in all vehicle details.');
          return false;
        }
        return true;
      case 1:
        if (_dobController.text.trim().isEmpty ||
            _dlNumberController.text.trim().isEmpty ||
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
        if (!_insuranceConfirmed) {
          _showError('Please confirm your general liability insurance coverage.');
          return false;
        }
        return true;
      case 3:
        if (_routingController.text.trim().length != 9) {
          _showError('Please enter a valid 9-digit routing number.');
          return false;
        }
        if (_accountController.text.trim().isEmpty) {
          _showError('Please enter your bank account number.');
          return false;
        }
        return true;
      case 4:
        if (!_termsAgreed) {
          _showError('Please agree to the Terms of Service to continue.');
          return false;
        }
        return true;
      default:
        return true;
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
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
    return supabase.storage.from('provider-documents').getPublicUrl(filename);
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
        'crew_size': _crewSize,
        'has_vehicle': _hasVehicle,
        'has_salt': _hasSalt,
        if (_hasVehicle) ...{
          'vehicle_make': _vehicleMakeController.text.trim(),
          'vehicle_model': _vehicleModelController.text.trim(),
          'vehicle_year': _vehicleYearController.text.trim(),
          'vehicle_vin': _vehicleVinController.text.trim().toUpperCase(),
          'vehicle_plate': _vehiclePlateController.text.trim().toUpperCase(),
        },
        'dob': _dobController.text.trim(),
        'dl_number': _dlNumberController.text.trim().toUpperCase(),
        'dl_state': _dlStateController.text.trim().toUpperCase(),
        if (dlUrl != null) 'dl_photo_url': dlUrl,
        'insurance_carrier': _insuranceCarrierController.text.trim(),
        'insurance_policy': _insurancePolicyController.text.trim().toUpperCase(),
        'insurance_expiry': _insuranceExpiryController.text.trim(),
        if (insuranceUrl != null) 'insurance_photo_url': insuranceUrl,
        'bank_routing': _routingController.text.trim(),
        'bank_account': _accountController.text.trim(),
        'terms_agreed': true,
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
            onPressed: () => supabase.auth.signOut(),
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
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
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
                  style: const TextStyle(color: Colors.grey, fontSize: 13)),
            ],
            const SizedBox(height: 20),
            child,
          ],
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
          const Text('Provider Type', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
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
          const Divider(height: 24),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('I have a vehicle (truck / plow)',
                style: TextStyle(fontWeight: FontWeight.w600)),
            value: _hasVehicle,
            activeColor: SnowServColors.iceBlue,
            onChanged: (val) => setState(() => _hasVehicle = val),
          ),
          if (_hasVehicle) ...[
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
            TextField(
              controller: _vehicleVinController,
              decoration: const InputDecoration(
                  labelText: 'VIN',
                  border: OutlineInputBorder(),
                  counterText: ''),
              textCapitalization: TextCapitalization.characters,
              maxLength: 17,
            ),
            const SizedBox(height: 8),
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
            title: const Text('I have salt',
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

  Widget _buildIdentityPage() {
    return _card(
      title: 'Identity Verification',
      subtitle: 'Required to confirm your identity before receiving jobs.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _dobController,
            decoration: const InputDecoration(
              labelText: 'Date of Birth (MM/DD/YYYY)',
              prefixIcon: Icon(Icons.cake_outlined),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.datetime,
          ),
          const SizedBox(height: 12),
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

  Widget _buildInsurancePage() {
    return _card(
      title: 'Insurance',
      subtitle: 'Valid general liability insurance is required to work on SnowServ.',
      child: Column(
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

  Widget _buildBankingPage() {
    return _card(
      title: 'Banking Details',
      subtitle: 'Used to pay you after each completed job.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 16, color: Colors.blue),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your banking information is stored securely and used only for payouts.',
                    style: TextStyle(fontSize: 12, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _routingController,
            decoration: const InputDecoration(
              labelText: 'Routing Number',
              prefixIcon: Icon(Icons.account_balance_outlined),
              border: OutlineInputBorder(),
              helperText: '9-digit number — bottom left of your check',
              counterText: '',
            ),
            keyboardType: TextInputType.number,
            maxLength: 9,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _accountController,
            decoration: const InputDecoration(
              labelText: 'Account Number',
              prefixIcon: Icon(Icons.credit_card_outlined),
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            obscureText: true,
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
          Container(
            height: 220,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: const SingleChildScrollView(
              child: Text(
                'SnowServ Provider Terms of Service\n\n'
                '1. INDEPENDENT CONTRACTOR\n'
                'You are an independent contractor, not an employee of SnowServ. You are responsible for your own taxes, insurance, and equipment.\n\n'
                '2. COMMISSION\n'
                'SnowServ retains 30% of each job as a platform fee. You receive 70% of the customer-paid amount.\n\n'
                '3. SERVICE STANDARDS\n'
                'You agree to complete all accepted jobs professionally and in a timely manner. Failure to complete accepted jobs may result in account suspension.\n\n'
                '4. INSURANCE\n'
                'You must maintain valid general liability insurance at all times while active on the platform.\n\n'
                '5. CONDUCT\n'
                'You agree to treat all customers respectfully and professionally. SnowServ reserves the right to suspend or terminate accounts for violations.\n\n'
                '6. PAYOUTS\n'
                'Payouts are processed within 3–5 business days after job completion and admin confirmation.\n\n'
                '7. JOB ACCEPTANCE\n'
                'When a job is dispatched to you, you have 3 minutes to accept or decline. Repeated timeouts may affect your standing on the platform.',
                style: TextStyle(fontSize: 13, color: Colors.black87, height: 1.5),
              ),
            ),
          ),
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
        ],
      ),
    );
  }

  Widget _photoUpload({required File? photo, required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: photo != null ? SnowServColors.iceBlue : Colors.grey.shade300,
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
                  Icon(Icons.upload_file, size: 32, color: Colors.grey.shade400),
                  const SizedBox(height: 8),
                  Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                  Text('Tap to take photo or upload from gallery',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
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
                  onPressed: () => Supabase.instance.client.auth.signOut(),
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
