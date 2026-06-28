import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final supabase = Supabase.instance.client;

class JobHistoryScreen extends StatefulWidget {
  const JobHistoryScreen({super.key});

  @override
  State<JobHistoryScreen> createState() => _JobHistoryScreenState();
}

class _JobHistoryScreenState extends State<JobHistoryScreen> {
  List<Map<String, dynamic>> completedJobs = [];
  bool loading = true;
  String? providerId;

  @override
  void initState() {
    super.initState();
    loadHistory();
  }

  Future<void> loadHistory() async {
    setState(() => loading = true);
    try {
      final providerData = await supabase
          .from('providers')
          .select('id')
          .eq('user_id', supabase.auth.currentUser!.id)
          .limit(1);

      if (providerData.isEmpty) return;
      providerId = providerData.first['id'].toString();

      final data = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('provider_id', providerId!)
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

  int providerPay(Map<String, dynamic> job) {
    final total = (job['final_price'] ?? job['base_price'] ?? 0) as num;
    return (total * 0.70).round();
  }

  int get totalEarnings =>
      completedJobs.fold(0, (sum, job) => sum + providerPay(job));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Job History'),
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
                  child: Text(
                    'No completed jobs yet.',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green.shade200),
                      ),
                      child: Column(
                        children: [
                          const Text('Total Earnings',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 14)),
                          const SizedBox(height: 4),
                          Text(
                            '\$$totalEarnings',
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Colors.green.shade700,
                            ),
                          ),
                          Text(
                            '${completedJobs.length} job${completedJobs.length == 1 ? '' : 's'} completed',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 13),
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
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(describeJob(job),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16)),
                                      Text(
                                        '\$${providerPay(job)}',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.green.shade700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (job['addresses'] != null) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.location_on,
                                            size: 14, color: Colors.grey),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            '${job['addresses']['address_line']}, ${job['addresses']['city']}, ${job['addresses']['state']}',
                                            style: const TextStyle(
                                                color: Colors.grey,
                                                fontSize: 13),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Text(
                                    formatDate(job['created_at']),
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 13),
                                  ),
                                  if (job['provider_notes'] != null &&
                                      job['provider_notes'].toString().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.note,
                                              size: 14, color: Colors.grey),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              job['provider_notes'],
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.black87),
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
                      ),
                    ),
                  ],
                ),
    );
  }
}
