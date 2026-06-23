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
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
      if (mounted) {
        final providerList = List<Map<String, dynamic>>.from(providersData);
        // pending_review first, then approved, then others
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
            Tab(text: 'Users (${users.length})'),
            Tab(text: 'Providers (${providers.length})'),
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
              ],
            ),
    );
  }

  Widget _roleBadge(String? role) {
    if (role == null || role.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: const Text('unknown', style: TextStyle(fontSize: 11, color: Colors.grey)),
      );
    }
    final isProvider = role == 'provider';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isProvider ? Colors.blue.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isProvider ? Colors.blue.shade300 : Colors.green.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isProvider ? Icons.build : Icons.person,
              size: 11, color: isProvider ? Colors.blue : Colors.green),
          const SizedBox(width: 3),
          Text(role,
              style: TextStyle(
                  fontSize: 11,
                  color: isProvider ? Colors.blue : Colors.green,
                  fontWeight: FontWeight.bold)),
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
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUsersTab() {
    if (users.isEmpty) return const Center(child: Text('No users yet.'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: users.length,
      itemBuilder: (context, i) {
        final user = users[i];
        final isFlagged = user['is_flagged'] == true;
        final isSuspended = user['is_suspended'] == true;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 13)),
                          const SizedBox(height: 4),
                          _roleBadge(user['role']),
                        ],
                      ),
                    ),
                    Column(
                      children: [
                        if (isFlagged)
                          const Icon(Icons.flag, color: Colors.orange, size: 20),
                        if (isSuspended)
                          const Icon(Icons.block, color: Colors.red, size: 20),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => toggleUserFlag(user['id'], isFlagged),
                        icon: Icon(isFlagged ? Icons.flag_outlined : Icons.flag,
                            size: 14),
                        label: Text(isFlagged ? 'Unflag' : 'Flag'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          side: const BorderSide(color: Colors.orange),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            toggleUserSuspend(user['id'], isSuspended),
                        icon: Icon(
                            isSuspended ? Icons.check_circle : Icons.block,
                            size: 14),
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
      },
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

    final pendingCount =
        providers.where((p) => p['registration_status'] == 'pending_review').length;

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
                const Icon(Icons.notification_important,
                    color: Colors.orange, size: 18),
                const SizedBox(width: 8),
                Text(
                  '$pendingCount application${pendingCount == 1 ? '' : 's'} pending review',
                  style: const TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: providers.length,
            itemBuilder: (context, i) {
              final p = providers[i];
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
            },
          ),
        ),
      ],
    );
  }
}
