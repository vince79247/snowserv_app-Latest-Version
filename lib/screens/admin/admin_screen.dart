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
        setState(() {
          jobs = List<Map<String, dynamic>>.from(jobsData);
          users = List<Map<String, dynamic>>.from(usersData);
          providers = List<Map<String, dynamic>>.from(providersData);
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

  Future<void> toggleProviderVerify(String providerId, bool currentVerified) async {
    await supabase.from('providers').update({'is_verified': !currentVerified}).eq('id', providerId);
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
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Navigator.pop(context),
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
                Text('\$${job['base_price']}',
                    style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
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

  Widget _buildProvidersTab() {
    if (providers.isEmpty) return const Center(child: Text('No providers yet.'));
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: providers.length,
      itemBuilder: (context, i) {
        final provider = providers[i];
        final isVerified = provider['is_verified'] == true;
        final isOnline = provider['is_online'] == true;
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
                          Text(provider['users']?['name'] ?? 'Unknown',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: SnowServColors.navy)),
                          Text(provider['users']?['email'] ?? '',
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 13)),
                          Text(provider['provider_type'] ?? '',
                              style: const TextStyle(
                                  color: SnowServColors.iceBlue, fontSize: 12)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (isVerified)
                          const Icon(Icons.verified, color: Colors.blue, size: 20),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: isOnline
                                ? Colors.green.shade50
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            isOnline ? 'Online' : 'Offline',
                            style: TextStyle(
                                fontSize: 11,
                                color: isOnline ? Colors.green : Colors.grey,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.star, size: 14, color: Colors.amber),
                    Text(' ${provider['rating'] ?? 0}',
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(width: 12),
                    const Icon(Icons.work, size: 14, color: Colors.grey),
                    Text(' ${provider['total_jobs'] ?? 0} jobs',
                        style: const TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        toggleProviderVerify(provider['id'], isVerified),
                    icon: Icon(
                        isVerified ? Icons.cancel_outlined : Icons.verified,
                        size: 14),
                    label: Text(isVerified ? 'Unverify' : 'Verify Provider'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor:
                          isVerified ? Colors.grey : Colors.blue,
                      side: BorderSide(
                          color: isVerified ? Colors.grey : Colors.blue),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
