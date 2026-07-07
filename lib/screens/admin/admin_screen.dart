import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';
import '../../utils/job_helpers.dart';
import '../../utils/geo.dart';
import 'zone_editor_screen.dart';

final supabase = Supabase.instance.client;

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
  List<Map<String, dynamic>> serviceAreas = [];
  bool loading = true;
  bool _payoutRunning = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
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
      // Loaded separately so a missing service_areas table (before the SQL is
      // run) doesn't break the rest of the admin panel.
      List<Map<String, dynamic>> areasList = [];
      try {
        final areasData = await supabase.from('service_areas').select().order('name');
        areasList = List<Map<String, dynamic>>.from(areasData);
      } catch (_) {}

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
          serviceAreas = areasList;
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

  // Admin "preferred driver" override (providers.preferred_until). While live,
  // this provider wins a new job only when they're EQUAL-OR-CLOSER than the
  // driver who'd otherwise get it (never sent a worse-distance job), and it
  // auto-expires at preferred_until. See migration
  // 20260707071500_preferred_driver_expiry_distance.sql + lib/utils/dispatch.dart.

  // True while the override is still live (future timestamp).
  bool _isPreferred(Map<String, dynamic> p) {
    final pu = p['preferred_until'];
    if (pu == null) return false;
    final until = DateTime.tryParse(pu.toString());
    return until != null && until.toUtc().isAfter(DateTime.now().toUtc());
  }

  // "3h 12m left" style remaining-time label (empty if not preferred).
  String _preferredRemaining(Map<String, dynamic> p) {
    final pu = p['preferred_until'];
    if (pu == null) return '';
    final until = DateTime.tryParse(pu.toString());
    if (until == null) return '';
    final left = until.toUtc().difference(DateTime.now().toUtc());
    if (left.isNegative) return '';
    final h = left.inHours;
    final m = left.inMinutes % 60;
    return h > 0 ? '${h}h ${m}m left' : '${m}m left';
  }

  Future<void> _setPreferred(String providerId, Duration? forDuration) async {
    await supabase.from('providers').update({
      'preferred_until': forDuration == null
          ? null
          : DateTime.now().toUtc().add(forDuration).toIso8601String(),
    }).eq('id', providerId);
    loadAll();
  }

  // Asks how long to prefer the driver; returns null if cancelled.
  Future<Duration?> _promptPreferredDuration() {
    return showDialog<Duration>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Prefer this driver for how long?'),
        children: [
          for (final opt in const [
            ['4 hours', 4],
            ['8 hours (a shift)', 8],
            ['24 hours', 24],
          ])
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, Duration(hours: opt[1] as int)),
              child: Text(opt[0] as String),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
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
    // On a wide screen (desktop browser) show every section at once as a
    // multi-column DASHBOARD — no tab-clicking. On a phone keep the tabs.
    final wide = MediaQuery.of(context).size.width >= 900;
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
        bottom: wide ? null : _buildTabBar(),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : (wide
              ? _buildDashboard()
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildJobsTab(),
                    _buildUsersTab(),
                    _buildProvidersTab(),
                    _buildPayoutsTab(),
                    _buildServiceAreasTab(),
                  ],
                )),
    );
  }

  int get _customerCount => users
      .where((u) => !providers
          .map((p) => p['user_id']?.toString())
          .toSet()
          .contains(u['id']?.toString()))
      .length;

  // ---- Computed admin metrics (all from already-loaded data) --------------

  String _customerName(dynamic customerId) {
    final u = users.firstWhere(
        (x) => x['id']?.toString() == customerId?.toString(),
        orElse: () => const {});
    final name = (u['name'] as String?)?.trim();
    return (name != null && name.isNotEmpty) ? name : 'Unknown';
  }

  num _jobPrice(Map<String, dynamic> j) =>
      (j['final_price'] ?? j['base_price'] ?? 0) as num;

  // A provider's currently-accepted/in-progress jobs (storm monitoring).
  List<Map<String, dynamic>> _activeJobsFor(String providerId) => jobs
      .where((j) =>
          j['provider_id']?.toString() == providerId &&
          (j['status'] == 'assigned' || j['status'] == 'in_progress'))
      .toList();

  List<Map<String, dynamic>> _completedFor(String providerId) => jobs
      .where((j) =>
          j['provider_id']?.toString() == providerId &&
          j['status'] == 'completed')
      .toList();

  // Platform-wide earnings from completed jobs. Provider take = 70%, platform 30%.
  num get _completedRevenue => jobs
      .where((j) => j['status'] == 'completed')
      .fold<num>(0, (s, j) => s + _jobPrice(j));
  num get _platformEarnings => _completedRevenue * 0.30;
  num get _providerEarnings => _completedRevenue * 0.70;

  Widget _earnTile(String label, num amount, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('\$${amount.round()}',
            style: TextStyle(
                color: color, fontSize: 20, fontWeight: FontWeight.bold)),
        Text(label,
            style: const TextStyle(color: Colors.white60, fontSize: 11)),
      ],
    );
  }

  TabBar _buildTabBar() {
    return TabBar(
      controller: _tabController,
      isScrollable: true,
      // High-contrast labels on the navy app bar (defaults render dim blue/grey).
      labelColor: Colors.white,
      unselectedLabelColor: SnowServColors.glacier,
      indicatorColor: Colors.white,
      indicatorWeight: 3,
      labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
      tabs: [
        Tab(text: 'Jobs (${jobs.length})'),
        Tab(text: 'Customers ($_customerCount)'),
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
        Tab(text: 'Zones (${serviceAreas.length})'),
      ],
    );
  }

  // Wide-screen dashboard: two columns of fixed-height panels, each reusing a
  // tab builder. Panels scroll internally; the page scrolls if the columns run
  // past the viewport. Everything visible without a single tab click.
  Widget _buildDashboard() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              children: [
                _dashPanel('Jobs (${jobs.length})', Icons.work_outline,
                    _buildJobsTab(), 640),
                _dashPanel(
                    pendingPayouts.isEmpty
                        ? 'Payouts'
                        : 'Payouts (${pendingPayouts.length} due)',
                    Icons.payments_outlined,
                    _buildPayoutsTab(),
                    480),
                _dashPanel('Zones (${serviceAreas.length})', Icons.map_outlined,
                    _buildServiceAreasTab(), 460),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                _dashPanel('Providers (${providers.length})',
                    Icons.local_shipping_outlined, _buildProvidersTab(), 640),
                _dashPanel('Customers ($_customerCount)', Icons.people_outline,
                    _buildUsersTab(), 560),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _dashPanel(String title, IconData icon, Widget child, double height) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        height: height,
        child: Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          elevation: 2,
          child: Column(
            children: [
              Container(
                width: double.infinity,
                color: SnowServColors.navy,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Icon(icon, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Text(title,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Provider documents (private bucket, admin-only viewing) --------------

  Widget _docViewButton(String label, dynamic pathOrUrl) {
    if (pathOrUrl == null || pathOrUrl.toString().isEmpty) {
      return _infoRow(label, 'not uploaded');
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _viewProviderDoc(label, pathOrUrl.toString()),
        icon: const Icon(Icons.image_outlined, size: 16),
        label: Text('View $label'),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  // Fetches a short-lived signed URL from the password-gated function and shows
  // the document. The private bucket + this function mean only the admin can
  // view provider licenses/insurance.
  Future<void> _viewProviderDoc(String title, String pathOrUrl) async {
    String? url;
    try {
      final resp = await supabase.functions.invoke('admin-doc-url', body: {
        'path': pathOrUrl,
      });
      if (resp.data is Map) url = resp.data['signed_url'] as String?;
    } catch (_) {}
    if (!mounted) return;
    if (url == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load document.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: InteractiveViewer(
                child: Image.network(
                  url!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Could not display image.'),
                  ),
                ),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  // ---- Service areas -------------------------------------------------------

  Future<void> _toggleAreaActive(Map<String, dynamic> area) async {
    await supabase
        .from('service_areas')
        .update({'is_active': !(area['is_active'] == true)})
        .eq('id', area['id']);
    loadAll();
  }

  Future<void> _deleteArea(Map<String, dynamic> area) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete zone?'),
        content: Text(
            'Remove "${area['name']}"? Customers inside its boundary will no longer be able to order.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await supabase.from('service_areas').delete().eq('id', area['id']);
    loadAll();
  }

  // Opens the map-based zone editor. The editor handles the insert/update and
  // pops true on save, so we just reload afterward.
  Future<void> _showAreaEditor([Map<String, dynamic>? area]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ZoneEditorScreen(zone: area)),
    );
    if (saved == true) loadAll();
  }

  Widget _buildServiceAreasTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () => _showAreaEditor(),
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Add Zone'),
            ),
          ),
        ),
        Expanded(
          child: serviceAreas.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No zones yet.\nAdd one and draw its boundary to start accepting orders there.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: serviceAreas.length,
                  itemBuilder: (context, i) {
                    final a = serviceAreas[i];
                    final active = a['is_active'] == true;
                    final pointCount = parsePolygon(a['polygon']).length;
                    final mapped = pointCount >= 3;
                    return Card(
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(a['name']?.toString() ?? 'Zone',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: SnowServColors.navy)),
                                ),
                                Text(active ? 'Active' : 'Off',
                                    style: TextStyle(color: active ? Colors.green : Colors.grey, fontWeight: FontWeight.w600, fontSize: 12)),
                                Switch(value: active, onChanged: (_) => _toggleAreaActive(a)),
                              ],
                            ),
                            Row(children: [
                              Icon(mapped ? Icons.check_circle : Icons.warning_amber_rounded,
                                  size: 15, color: mapped ? Colors.green : Colors.orange),
                              const SizedBox(width: 4),
                              Text(
                                mapped ? 'Mapped ($pointCount points)' : 'Not mapped yet — draw a boundary',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: mapped ? Colors.black87 : Colors.orange.shade800),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            Text(
                              'Sidewalk \$${a['price_sidewalk']}  •  Driveway \$${a['price_driveway']}  •  Both \$${a['price_both']}  •  Deicer +\$${a['price_salting']}',
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  onPressed: () => _showAreaEditor(a),
                                  icon: const Icon(Icons.edit, size: 16),
                                  label: const Text('Edit'),
                                ),
                                TextButton.icon(
                                  onPressed: () => _deleteArea(a),
                                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                  label: const Text('Delete', style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
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
                if (job['job_number'] != null)
                  Text('Job #${job['job_number']}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
                Row(
                  children: [
                    const Icon(Icons.person, size: 13, color: SnowServColors.navy),
                    const SizedBox(width: 4),
                    Text(_customerName(job['customer_id']),
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: SnowServColors.navy)),
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

              final activeJobs = _activeJobsFor(p['id'].toString());
              final completed = _completedFor(p['id'].toString());
              final earned = completed.fold<num>(0, (s, j) => s + _jobPrice(j)) * 0.70;

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
                        // Live workload — the storm-monitoring at-a-glance.
                        if (activeJobs.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.bolt, size: 13, color: SnowServColors.iceBlue),
                          Text(' ${activeJobs.length} active',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: SnowServColors.iceBlue,
                                  fontWeight: FontWeight.w700)),
                        ],
                        // Post-start cancels charge the customer then bail —
                        // the most abusable provider move, so flag repeats.
                        if ((p['cancelled_after_start_count'] ?? 0) > 0) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.warning_amber_rounded,
                              size: 13, color: Colors.red),
                          Text(
                              ' ${p['cancelled_after_start_count']} cancel${p['cancelled_after_start_count'] == 1 ? '' : 's'} after start',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.red,
                                  fontWeight: FontWeight.w600)),
                        ],
                        // Preferred-driver override active — visible at a glance
                        // (with time left) so the admin remembers it's on.
                        if (_isPreferred(p)) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.star, size: 13, color: Colors.amber.shade700),
                          Text(' Preferred · ${_preferredRemaining(p)}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.amber.shade700,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ],
                    ),
                  ),
                  children: [
                    const Divider(height: 16),
                    // Earnings (this driver's 70% take of their completed jobs).
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.payments, size: 16, color: Colors.green.shade700),
                          const SizedBox(width: 8),
                          Text(
                              'Earned \$${earned.round()}  ·  ${completed.length} completed',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green.shade800)),
                        ],
                      ),
                    ),
                    // Live workload — the accepted/in-progress jobs (storms).
                    if (activeJobs.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Active now (${activeJobs.length})',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: SnowServColors.iceBlue)),
                      ),
                      const SizedBox(height: 4),
                      ...activeJobs.map((j) {
                        final addr = j['addresses'];
                        final where = addr != null
                            ? '${addr['address_line']}, ${addr['city']}'
                            : 'Address on file';
                        final inProg = j['status'] == 'in_progress';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Icon(inProg ? Icons.play_circle : Icons.check_circle_outline,
                                  size: 14,
                                  color: inProg ? Colors.blue : Colors.orange),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '$where  ·  ${describeJob(j)}  ·  ${inProg ? 'In progress' : 'Accepted'}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                    const SizedBox(height: 10),
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
                    _infoRow('Has deicer', hasSalt ? 'Yes' : 'No'),
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
                    _docViewButton('DL photo', p['dl_photo_url']),
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
                    _docViewButton('Insurance card', p['insurance_photo_url']),
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
                      // Preferred-driver override: while live, this driver wins a
                      // new job only when they're equal-or-closer than whoever
                      // would otherwise get it (never sent a worse-distance job).
                      // Auto-expires; toggle off any time to end it early.
                      Builder(builder: (_) {
                        final pref = _isPreferred(p);
                        return Container(
                          decoration: BoxDecoration(
                            color: pref
                                ? Colors.amber.withOpacity(0.12)
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: pref
                                  ? Colors.amber.shade700
                                  : SnowServColors.glacier,
                            ),
                          ),
                          child: SwitchListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            dense: true,
                            activeThumbColor: Colors.amber.shade700,
                            secondary: Icon(Icons.star,
                                color: pref ? Colors.amber.shade700 : Colors.grey),
                            title: const Text('Preferred driver',
                                style: TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 14)),
                            subtitle: Text(
                                pref
                                    ? 'Wins nearby jobs when equal-or-closer than the '
                                        'next driver · ${_preferredRemaining(p)}'
                                    : 'Favor this driver for close jobs, for a set time. '
                                        'Never sent a farther job than normal.',
                                style: const TextStyle(fontSize: 11)),
                            value: pref,
                            onChanged: (v) async {
                              if (v) {
                                final dur = await _promptPreferredDuration();
                                if (dur != null) _setPreferred(p['id'], dur);
                              } else {
                                _setPreferred(p['id'], null);
                              }
                            },
                          ),
                        );
                      }),
                      const SizedBox(height: 8),
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
        // All-time earnings from completed jobs (your 30% vs. providers' 70%).
        Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: SnowServColors.navy,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Earnings (completed jobs)',
                  style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _earnTile('Your cut (30%)', _platformEarnings, Colors.white),
                  _earnTile('Providers (70%)', _providerEarnings,
                      SnowServColors.glacier),
                  _earnTile('Total', _completedRevenue, Colors.amber),
                ],
              ),
            ],
          ),
        ),
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
