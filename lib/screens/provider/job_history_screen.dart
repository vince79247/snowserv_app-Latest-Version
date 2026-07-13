import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/job_helpers.dart';
import '../../utils/dispute.dart';
import '../../theme.dart';

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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history,
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
                          Text('Total Earnings',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 4),
                          Text(
                            '\$$totalEarnings',
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            '${completedJobs.length} job${completedJobs.length == 1 ? '' : 's'} completed',
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
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (job['job_number'] != null)
                                    Text('Job #${job['job_number']}',
                                        style: const TextStyle(fontSize: 11, color: SnowServColors.inkSoft)),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Flexible(
                                        child: Text(describeJob(job),
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                                color: SnowServColors.navy)),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '\$${providerPay(job)}',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: SnowServColors.success,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (job['addresses'] != null) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.location_on,
                                            size: 14,
                                            color: SnowServColors.inkSoft),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            '${job['addresses']['address_line']}, ${job['addresses']['city']}, ${job['addresses']['state']}',
                                            style: const TextStyle(
                                                color: SnowServColors.inkSoft,
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
                                        color: SnowServColors.inkSoft,
                                        fontSize: 13),
                                  ),
                                  if (job['provider_notes'] != null &&
                                      job['provider_notes'].toString().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: SnowServColors.surfaceSoft,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                            color: SnowServColors.hairline),
                                      ),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Icon(Icons.note,
                                              size: 14,
                                              color: SnowServColors.inkSoft),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              job['provider_notes'],
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  color: SnowServColors.ink),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: reportProblemButton(context, job, isProvider: true),
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
