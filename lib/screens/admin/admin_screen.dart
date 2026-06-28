import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';

final supabase = Supabase.instance.client;
const _adminPassword = 'SnowServ@Admin2026';

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _passwordController = TextEditingController();
  bool _obscure = true;
  String? _error;

  void _login() {
    if (_passwordController.text == _adminPassword) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
      );
    } else {
      setState(() => _error = 'Incorrect password.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SnowServColors.navy,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.admin_panel_settings, size: 64, color: Colors.white),
              const SizedBox(height: 16),
              const Text('Admin Panel',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('SnowServ', style: TextStyle(color: SnowServColors.glacier, fontSize: 14)),
              const SizedBox(height: 40),
              TextField(
                controller: _passwordController,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(
                  labelText: 'Admin Password',
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onSubmitted: (_) => _login(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SnowServColors.iceBlue,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Enter', style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> jobs = [];
  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> providers = [];
  List<Map<String, dynamic>> pendingPayouts = [];
  bool loading = true;
  bool _payoutRunning = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    loadAll();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> loadAll() async {
    setState(() => loading = true);
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7)).toUtc().toIso8601String();
      final jobsData = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .order('created_at', ascending: false);
      final usersData = await supabase
          .from('users')
          .select()
          .order('created_at', ascending: false);
      final providersData = await supabase
          .from('providers')
          .select('*, users!inner(name, email)')
          .order('created_at', ascending: false);
      final payoutsData = await supabase
          .from('jobs')
          .select('*, providers!jobs_provider_id_fkey!inner(users!inner(name))')
          .eq('status', 'completed')
          .eq('payout_status', 'pending')
          .lt('created_at', cutoff)
          .order('created_at', ascending: false);
      if (mounted) {
        final providerList = List<Map<String, dynamic>>.from(providersData);
        providerList.sort((a, b) {
          const order = {'pending_review': 0, 'approved': 1};
          final aOrder = order[a['registration_status']] ?? 2;
          final bOrder = order[b['registration_status']] ?? 2;
          return aOrder.compareTo(bOrder);
        });
        setState(() {
          jobs = List<Map<String, dynamic>>.from(jobsData);
          users = List<Map<String, dynamic>>.from(usersData);
          providers = providerList;
          pendingPayouts = List<Map<String, dynamic>>.from(payoutsData);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading data: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> toggleUserFlag(String userId, bool currentFlag) async {
    await supabase.from('users').update({'is_flagged': !currentFlag}).eq('id', userId);
    loadAll();
  }

  Future<void> toggleUserSuspend(String userId, bool currentSuspend) async {
    await supabase.from('users').update({'is_suspended': !currentSuspend}).eq('id', userId);
    loadAll();
  }

  Future<void> approveProvider(String providerId) async {
    await supabase.from('providers').update({
      'is_verified': true,
      'registration_status': 'approved',
    }).eq('id', providerId);
    loadAll();
  }

  Future<void> rejectProvider(String providerId) async {
    await supabase.from('providers').update({
      'is_verified': false,
      'registration_status': 'rejected',
    }).eq('id', providerId);
    loadAll();
  }

  Future<void> revokeProvider(String providerId) async {
    await supabase.from('providers').update({
      'is_verified': false,
      'registration_status': 'rejected',
    }).eq('id', providerId);
    loadAll();
  }

  String describeJob(Map<String, dynamic> job) {
    final List<String> services = [];
    if (job['driveway'] == true) services.add('Driveway');
    if (job['walkway'] == true) services.add('Sidewalk');
    if (job['salting'] == true) services.add('Salting');
    return services.isEmpty ? 'Service' : services.join(' + ');
  }

  String formatDate(String dateStr) {
    final date = DateTime.parse(dateStr).toLocal();
    return '${date.month}/${date.day}/${date.year}';
  }

  Color statusColor(String status) {
    switch (status) {
      case 'requested': return Colors.orange;
      case 'assigned': return SnowServColors.iceBlue;
      case 'in_progress': return Colors.green;
      case 'completed': return Colors.grey;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadAll),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Log Out', style: TextStyle(color: Colors.white)),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Jobs (${jobs.length})'),
            Tab(text: 'Customers (${users.where((u) => !providers.map((p) => p['user_id']?.toString()).toSet().contains(u['id']?.toString())).length})'),
            Tab(text: 'Providers (${providers.length})'),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Payouts'),
                  if (pendingPayouts.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    CircleAvatar(
                      radius: 8,
                      backgroundColor: Colors.red,
                      child: Text('${pendingPayouts.length}',
                          style: const TextStyle(fontSize: 10, color: Colors.white)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildJobsTab(),
                _buildUsersTab(),
                _buildProvidersTab(),
                _buildPayoutsTab(),
              ],
            ),
    );
  }

  Widget _buildJobsTab() {
    if (jobs.isEmpty) return const Center(child: Text('No jobs yet.'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: jobs.length,
      itemBuilder: (context, i) {
        final job = jobs[i];
        final hasNotes = job['provider_notes'] != null &&
            job['provider_notes'].toString().isNotEmpty;
        final photos = (job['completion_photos'] as List<dynamic>? ?? []);
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(describeJob(job),
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: SnowServColors.navy)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor(job['status']).withOpacity(0.15),
                        border: Border.all(color: statusColor(job['status'])),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(job['status'],
                          style: TextStyle(
                              color: statusColor(job['status']),
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Customer paid: \$${job['final_price'] ?? job['base_price']}',
                          style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                              fontSize: 15),
                        ),
                        Text(
                          'Provider pay: \$${(((job['final_price'] ?? job['base_price'] ?? 0) as num) * 0.70).round()}  |  Commission: \$${(((job['final_price'] ?? job['base_price'] ?? 0) as num) * 0.30).round()}',
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                    if ((job['surge_multiplier'] ?? 1.0) > 1.0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: Text(
                          '${job['surge_multiplier']}x surge',
                          style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ],
                ),
                if (job['addresses'] != null)
                  Text(
                    '${job['addresses']['address_line']}, ${job['addresses']['city']}',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                Text(formatDate(job['created_at']),
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                if (hasNotes) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      border: Border.all(color: Colors.amber.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.note_alt, size: 16, color: Colors.amber),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Provider Notes',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.amber)),
                              Text(job['provider_notes'],
                                  style: const TextStyle(fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (photos.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('Completion Photos',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey)),
                  const SizedBox(height: 6),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 6,
                      mainAxisSpacing: 6,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (_, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        photos[i].toString(),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image, color: Colors.grey),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _userCard(Map<String, dynamic> user) {
    final isFlagged = user['is_flagged'] == true;
    final isSuspended = user['is_suspended'] == true;

    Color borderColor = Colors.transparent;
    if (isSuspended) borderColor = Colors.red;
    else if (isFlagged) borderColor = Colors.orange;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor, width: isFlagged || isSuspended ? 1.5 : 0),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user['name'] ?? user['email'] ?? 'Unknown',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                              color: SnowServColors.navy)),
                      Text(user['email'] ?? '',
                          style: const TextStyle(color: Colors.grey, fontSize: 13)),
                      if (user['phone'] != null) ...[
                        const SizedBox(height: 2),
                        Text(user['phone'],
                            style: const TextStyle(color: Colors.grey, fontSize: 13)),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (isSuspended)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.block, size: 11, color: Colors.red),
                            SizedBox(width: 4),
                            Text('Suspended', style: TextStyle(fontSize: 11, color: Colors.red, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    if (isFlagged) ...[
                      if (isSuspended) const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.flag, size: 11, color: Colors.orange),
                            SizedBox(width: 4),
                            Text('Under Review', style: TextStyle(fontSize: 11, color: Colors.orange, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            if (isSuspended) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 13, color: Colors.red),
                    SizedBox(width: 6),
                    Text('Account blocked — customer cannot place orders',
                        style: TextStyle(fontSize: 12, color: Colors.red)),
                  ],
                ),
              ),
            ],
            if (isFlagged && !isSuspended) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 13, color: Colors.orange),
                    SizedBox(width: 6),
                    Text('Account active — flagged for admin attention',
                        style: TextStyle(fontSize: 12, color: Colors.orange)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => toggleUserFlag(user['id'], isFlagged),
                    icon: Icon(isFlagged ? Icons.flag_outlined : Icons.flag, size: 14),
                    label: Text(isFlagged ? 'Remove Flag' : 'Flag'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => toggleUserSuspend(user['id'], isSuspended),
                    icon: Icon(isSuspended ? Icons.check_circle : Icons.block, size: 14),
                    label: Text(isSuspended ? 'Unsuspend' : 'Suspend'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersTab() {
    final providerUserIds = providers.map((p) => p['user_id']?.toString()).toSet();
    final customers = users.where((u) => !providerUserIds.contains(u['id']?.toString())).toList();
    final flaggedCount = customers.where((u) => u['is_flagged'] == true).length;
    final suspendedCount = customers.where((u) => u['is_suspended'] == true).length;

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: SnowServColors.navy.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _tallyItem('Total', customers.length, Colors.black87),
              _tallyItem('Flagged', flaggedCount, Colors.orange.shade700),
              _tallyItem('Suspended', suspendedCount, Colors.red.shade700),
            ],
          ),
        ),
        if (customers.isEmpty)
          const Expanded(child: Center(child: Text('No customers yet.')))
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: customers.length,
              itemBuilder: (_, i) => _userCard(customers[i]),
            ),
          ),
      ],
    );
  }

  Widget _registrationBadge(String? status) {
    Color color;
    IconData icon;
    String label;
    switch (status) {
      case 'pending_review':
        color = Colors.orange;
        icon = Icons.hourglass_top;
        label = 'Pending Review';
        break;
      case 'approved':
        color = Colors.green;
        icon = Icons.verified;
        label = 'Approved';
        break;
      case 'rejected':
        color = Colors.red;
        icon = Icons.cancel;
        label = 'Rejected';
        break;
      default:
        color = Colors.grey;
        icon = Icons.edit_note;
        label = 'Incomplete';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ),
        ],
      ),
    );
  }

  Widget _buildProvidersTab() {
    if (providers.isEmpty) return const Center(child: Text('No providers yet.'));

    final pendingCount = providers.where((p) => p['registration_status'] == 'pending_review').length;
    final onDuty = providers.where((p) => p['is_online'] == true).toList();
    final offDuty = providers.where((p) => p['is_online'] != true).toList();

    Widget buildProviderCard(Map<String, dynamic> p) {
              final isOnline = p['is_online'] == true;
              final regStatus = p['registration_status'] as String?;
              final isPending = regStatus == 'pending_review';
              final isApproved = regStatus == 'approved';

              final hasVehicle = p['has_vehicle'] == true;
              final hasSalt = p['has_salt'] == true;

              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: isPending
                      ? const BorderSide(color: Colors.orange, width: 1.5)
                      : BorderSide.none,
                ),
                child: ExpansionTile(
                  tilePadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  childrenPadding:
                      const EdgeInsets.fromLTRB(14, 0, 14, 14),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              p['users']?['name'] ?? 'Unknown',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: SnowServColors.navy),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: isOnline
                                  ? Colors.green.shade50
                                  : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              isOnline ? 'Online' : 'Offline',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: isOnline ? Colors.green : Colors.grey,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      Text(p['users']?['email'] ?? '',
                          style:
                              const TextStyle(color: Colors.grey, fontSize: 12)),
                      const SizedBox(height: 4),
                      _registrationBadge(regStatus),
                    ],
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.star, size: 13, color: Colors.amber),
                        Text(' ${p['rating'] ?? 0}  ',
                            style: const TextStyle(fontSize: 12)),
                        const Icon(Icons.work, size: 13, color: Colors.grey),
                        Text(' ${p['total_jobs'] ?? 0} jobs',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  children: [
                    const Divider(height: 16),
                    // Equipment section
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Equipment',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: SnowServColors.navy)),
                    ),
                    const SizedBox(height: 6),
                    _infoRow('Type', p['provider_type']),
                    _infoRow('Crew size', '${p['crew_size'] ?? 1}'),
                    _infoRow('Has vehicle',
                        hasVehicle ? 'Yes' : 'No'),
                    if (hasVehicle) ...[
                      _infoRow('Vehicle',
                          '${p['vehicle_year'] ?? ''} ${p['vehicle_make'] ?? ''} ${p['vehicle_model'] ?? ''}'.trim()),
                      _infoRow('VIN', p['vehicle_vin']),
                      _infoRow('Plate', p['vehicle_plate']),
                    ],
                    _infoRow('Has salt', hasSalt ? 'Yes' : 'No'),
                    const SizedBox(height: 10),
                    // Identity section
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Identity',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: SnowServColors.navy)),
                    ),
                    const SizedBox(height: 6),
                    _infoRow('Date of birth', p['dob']),
                    _infoRow("Driver's license", '${p['dl_number'] ?? ''}  ${p['dl_state'] ?? ''}'.trim()),
                    if (p['dl_photo_url'] != null)
                      _infoRow('DL photo', '✓ uploaded'),
                    const SizedBox(height: 10),
                    // Insurance section
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Insurance',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: SnowServColors.navy)),
                    ),
                    const SizedBox(height: 6),
                    _infoRow('Carrier', p['insurance_carrier']),
                    _infoRow('Policy #', p['insurance_policy']),
                    _infoRow('Expiry', p['insurance_expiry']),
                    if (p['insurance_photo_url'] != null)
                      _infoRow('Card photo', '✓ uploaded'),
                    const SizedBox(height: 10),
                    // Banking section
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Banking',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: SnowServColors.navy)),
                    ),
                    const SizedBox(height: 6),
                    _infoRow('Routing', p['bank_routing'] != null
                        ? '••••${(p['bank_routing'] as String).substring((p['bank_routing'] as String).length - 4)}'
                        : null),
                    _infoRow('Account', p['bank_account'] != null ? '••••••••' : null),
                    const SizedBox(height: 14),
                    // Action buttons
                    if (isPending) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => approveProvider(p['id']),
                              icon: const Icon(Icons.verified, size: 14),
                              label: const Text('Approve'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => rejectProvider(p['id']),
                              icon: const Icon(Icons.cancel_outlined, size: 14),
                              label: const Text('Reject'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red,
                                side: const BorderSide(color: Colors.red),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else if (isApproved) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => revokeProvider(p['id']),
                          icon: const Icon(Icons.cancel_outlined, size: 14),
                          label: const Text('Revoke Approval'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
    }

    return Column(
      children: [
        if (pendingCount > 0)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.shade300),
            ),
            child: Row(
              children: [
                const Icon(Icons.notification_important, color: Colors.orange, size: 18),
                const SizedBox(width: 8),
                Text(
                  '$pendingCount application${pendingCount == 1 ? '' : 's'} pending review',
                  style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
          ),
        Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: SnowServColors.navy.withOpacity(0.05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _tallyItem('Total', providers.length, Colors.black87),
              _tallyItem('On Duty', onDuty.length, Colors.green.shade700),
              _tallyItem('Off Duty', offDuty.length, Colors.grey.shade600),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (onDuty.isNotEmpty) ...[
                _sectionHeader('On Duty (${onDuty.length})', Colors.green.shade700),
                ...onDuty.map(buildProviderCard),
              ],
              if (offDuty.isNotEmpty) ...[
                _sectionHeader('Off Duty (${offDuty.length})', Colors.grey.shade600),
                ...offDuty.map(buildProviderCard),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _tallyItem(String label, int count, Color color) {
    return Column(
      children: [
        Text('$count', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _sectionHeader(String title, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 6),
      child: Row(
        children: [
          Container(width: 4, height: 16, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
        ],
      ),
    );
  }

  Future<void> _runPayouts() async {
    setState(() => _payoutRunning = true);
    try {
      final result = await supabase.functions.invoke('batch-payouts');
      final processed = result.data['processed'] ?? 0;
      final results = (result.data['results'] as List? ?? []);
      final paid = results.where((r) => r['status'] == 'paid').length;
      final errors = results.where((r) => r['status'] == 'error').length;
      await loadAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Processed $processed payouts — $paid paid, $errors errors'),
          backgroundColor: errors > 0 ? Colors.orange : Colors.green,
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Payout error: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _payoutRunning = false);
    }
  }

  Widget _buildPayoutsTab() {
    final totalDue = pendingPayouts.fold<double>(
      0,
      (sum, job) => sum + ((job['final_price'] ?? job['base_price'] ?? 0) as num) * 0.70,
    );

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.shade200),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${pendingPayouts.length} payouts due',
                          style: const TextStyle(fontWeight: FontWeight.bold,
                              fontSize: 15, color: SnowServColors.navy)),
                      Text('Jobs completed 7+ days ago',
                          style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                    ],
                  ),
                  Text('\$${totalDue.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700)),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: pendingPayouts.isEmpty || _payoutRunning ? null : _runPayouts,
                  icon: _payoutRunning
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.payments_outlined),
                  label: Text(_payoutRunning ? 'Processing...' : 'Process All Payouts'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (pendingPayouts.isEmpty)
          const Expanded(
            child: Center(
              child: Text('No payouts due.', style: TextStyle(color: Colors.grey, fontSize: 16)),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: pendingPayouts.length,
              itemBuilder: (context, i) {
                final job = pendingPayouts[i];
                final providerName = job['providers']?['users']?['name'] ?? 'Unknown';
                final providerPay = ((job['final_price'] ?? job['base_price'] ?? 0) as num) * 0.70;
                final date = DateTime.parse(job['created_at']).toLocal();
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    title: Text(providerName,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(
                      '${describeJob(job)} · ${date.month}/${date.day}/${date.year}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: Text(
                      '\$${providerPay.toStringAsFixed(2)}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Colors.green.shade700),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
