import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/job_helpers.dart';
import '../../utils/dispute.dart';
import '../../theme.dart';

final supabase = Supabase.instance.client;

class CustomerJobHistoryScreen extends StatefulWidget {
  const CustomerJobHistoryScreen({super.key});

  @override
  State<CustomerJobHistoryScreen> createState() =>
      _CustomerJobHistoryScreenState();
}

class _CustomerJobHistoryScreenState extends State<CustomerJobHistoryScreen> {
  List<Map<String, dynamic>> completedJobs = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    loadHistory();
  }

  Future<void> rateJob(String jobId, String? providerId, int stars) async {
    try {
      // Server-side (SECURITY DEFINER): verifies we own this completed job, records
      // the star rating and recomputes the provider's average. The customer no
      // longer writes the provider's row directly (RLS forbids it now).
      await supabase.rpc('rate_job', params: {'p_job_id': jobId, 'p_stars': stars});
      loadHistory();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rating failed: $e')),
        );
      }
    }
  }

  Future<void> loadHistory() async {
    setState(() => loading = true);
    try {
      // Explicit columns only — never '*' — so provider_notes and other admin-only
      // fields are not shipped to the customer's device (see customer_home loadMyJobs).
      final data = await supabase
          .from('jobs')
          // customer_id is REQUIRED here: "Report a problem" inserts it, and the
          // disputes RLS insert policy checks auth.uid() = customer_id. Without
          // it the insert sent null and every customer dispute failed with 42501
          // (found 2026-07-29). Explicit column list on purpose — never select *
          // here, so provider_notes can't leak to a customer.
          .select('id, customer_id, job_number, status, service_type, driveway, walkway, salting, '
              'base_price, surge_multiplier, final_price, snow_level, completion_photos, '
              'customer_rating, created_at, provider_id, addresses(*)')
          .eq('customer_id', supabase.auth.currentUser!.id)
          .eq('status', 'completed')
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() => completedJobs = List<Map<String, dynamic>>.from(data));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading history: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  int get totalSpent =>
      completedJobs.fold(0, (sum, job) => sum + ((job['final_price'] ?? job['base_price']) as int? ?? 0));

  void showReceipt(Map<String, dynamic> job) {
    final photos = job['completion_photos'] as List<dynamic>? ?? [];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Receipt',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: SnowServColors.navy),
                  textAlign: TextAlign.center),
              if (job['job_number'] != null)
                Text('Job #${job['job_number']}',
                    style: const TextStyle(
                        color: SnowServColors.inkSoft, fontSize: 13),
                    textAlign: TextAlign.center),
              const Divider(height: 24),
              _receiptRow('Service', describeJob(job)),
              if (job['addresses'] != null)
                _receiptRow('Address',
                    '${job['addresses']['address_line']}, ${job['addresses']['city']}, ${job['addresses']['state']} ${job['addresses']['zip']}'),
              _receiptRow('Date', formatDate(job['created_at'])),
              const Divider(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Total Paid',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: SnowServColors.navy)),
                  Text('\$${job['final_price'] ?? job['base_price']}',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: SnowServColors.success)),
                ],
              ),
              if (photos.isNotEmpty) ...[
                const Divider(height: 24),
                const Text('Completion Photos',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: SnowServColors.navy)),
                const SizedBox(height: 8),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      photos[i].toString(),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image,
                              color: SnowServColors.glacier),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _receiptRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: const TextStyle(
                    color: SnowServColors.inkSoft, fontSize: 14)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Home icon instead of the default back arrow — this screen returns to
        // the home screen, so a house makes the destination obvious.
        leading: IconButton(
          icon: const Icon(Icons.home_outlined),
          tooltip: 'Home',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('My Orders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: loadHistory,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : completedJobs.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 56, color: SnowServColors.glacier),
                      SizedBox(height: 12),
                      Text(
                        'No completed jobs yet.',
                        style: TextStyle(
                            fontSize: 16, color: SnowServColors.inkSoft),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            SnowServColors.navy,
                            SnowServColors.navyMid
                          ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Text('Total Spent',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(
                            '\$$totalSpent',
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            '${completedJobs.length} service${completedJobs.length == 1 ? '' : 's'}',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: completedJobs.length,
                        itemBuilder: (context, index) {
                          final job = completedJobs[index];
                          final rated = job['customer_rating'] as int?;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (job['job_number'] != null)
                                              Text('Job #${job['job_number']}',
                                                  style: const TextStyle(fontSize: 11, color: SnowServColors.inkSoft)),
                                            Text(describeJob(job),
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: SnowServColors.navy)),
                                            const SizedBox(height: 2),
                                            if (job['addresses'] != null)
                                              Text(
                                                '${job['addresses']['address_line']}, ${job['addresses']['city']}',
                                                style: const TextStyle(color: SnowServColors.inkSoft, fontSize: 13),
                                              ),
                                            Text(formatDate(job['created_at']),
                                                style: const TextStyle(color: SnowServColors.inkSoft, fontSize: 13)),
                                          ],
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () => showReceipt(job),
                                        child: Column(
                                          children: [
                                            Text('\$${job['final_price'] ?? job['base_price']}',
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: SnowServColors.success)),
                                            const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text('Receipt', style: TextStyle(color: SnowServColors.iceBlue, fontSize: 12, fontWeight: FontWeight.w600)),
                                                Icon(Icons.chevron_right, color: SnowServColors.iceBlue, size: 16),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  const Divider(
                                      height: 1, color: SnowServColors.hairline),
                                  const SizedBox(height: 10),
                                  if (rated == null) ...[
                                    const Text('How was your service?',
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: SnowServColors.navy)),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: List.generate(5, (i) => GestureDetector(
                                        onTap: () => rateJob(job['id'].toString(), job['provider_id']?.toString(), i + 1),
                                        child: Padding(
                                          padding: const EdgeInsets.only(right: 4),
                                          child: Icon(Icons.star_border, color: Colors.amber, size: 32),
                                        ),
                                      )),
                                    ),
                                  ] else
                                    Row(
                                      children: [
                                        ...List.generate(5, (i) => Icon(
                                          i < rated ? Icons.star : Icons.star_border,
                                          color: Colors.amber,
                                          size: 22,
                                        )),
                                        const SizedBox(width: 6),
                                        const Text('You rated this service',
                                            style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft)),
                                      ],
                                    ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: reportProblemButton(context, job, isProvider: false),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
