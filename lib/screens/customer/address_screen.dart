import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';

final supabase = Supabase.instance.client;

class AddressScreen extends StatefulWidget {
  final Map<String, dynamic>? existingAddress;
  const AddressScreen({super.key, this.existingAddress});

  @override
  State<AddressScreen> createState() => _AddressScreenState();
}

class _AddressScreenState extends State<AddressScreen> {
  late final TextEditingController addressController;
  late final TextEditingController cityController;
  late final TextEditingController stateController;
  late final TextEditingController zipController;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    final a = widget.existingAddress;
    addressController = TextEditingController(text: a?['address_line'] ?? '');
    cityController = TextEditingController(text: a?['city'] ?? '');
    stateController = TextEditingController(text: a?['state'] ?? '');
    zipController = TextEditingController(text: a?['zip'] ?? '');
  }

  @override
  void dispose() {
    addressController.dispose();
    cityController.dispose();
    stateController.dispose();
    zipController.dispose();
    super.dispose();
  }

  Future<void> saveAddress() async {
    if (addressController.text.trim().isEmpty ||
        cityController.text.trim().isEmpty ||
        stateController.text.trim().isEmpty ||
        zipController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields.')),
      );
      return;
    }
    setState(() => loading = true);
    try {
      final userId = supabase.auth.currentUser!.id;
      final existing = widget.existingAddress;
      if (existing != null) {
        await supabase.from('addresses').update({
          'address_line': addressController.text.trim(),
          'city': cityController.text.trim(),
          'state': stateController.text.trim(),
          'zip': zipController.text.trim(),
        }).eq('id', existing['id']);
      } else {
        await supabase.from('addresses').insert({
          'user_id': userId,
          'address_line': addressController.text.trim(),
          'city': cityController.text.trim(),
          'state': stateController.text.trim(),
          'zip': zipController.text.trim(),
        });
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving address: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingAddress != null ? 'Edit Address' : 'Add Your Address'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: SnowServColors.iceBlue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: SnowServColors.glacier),
              ),
              child: const Row(
                children: [
                  Icon(Icons.location_on, color: SnowServColors.iceBlue),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'We need your address so providers know where to go.',
                      style: TextStyle(color: SnowServColors.navyMid, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '* All fields are required',
              style: TextStyle(fontSize: 12, color: Colors.red),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: 'Street Address *',
                hintText: '123 Main St',
                prefixIcon: Icon(Icons.home_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cityController,
              decoration: const InputDecoration(
                labelText: 'City *',
                prefixIcon: Icon(Icons.location_city_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: stateController,
                    decoration: const InputDecoration(
                      labelText: 'State *',
                      hintText: 'NY',
                      prefixIcon: Icon(Icons.map_outlined),
                    ),
                    textCapitalization: TextCapitalization.characters,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: zipController,
                    decoration: const InputDecoration(
                      labelText: 'ZIP Code *',
                      hintText: '10001',
                      prefixIcon: Icon(Icons.pin_outlined),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: loading ? null : saveAddress,
              child: loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Save Address'),
            ),
          ],
        ),
      ),
    );
  }
}
