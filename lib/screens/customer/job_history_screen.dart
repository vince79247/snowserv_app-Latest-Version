import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      await supabase.from('jobs').update({'customer_rating': stars}).eq('id', jobId);
      if (providerId != null) {
        final ratedJobs = await supabase
            .from('jobs')
            .select('customer_rating')
            .eq('provider_id', providerId)
            .not('customer_rating', 'is', null);
        if (ratedJobs.isNotEmpty) {
          final ratings = (ratedJobs as List)
              .map((j) => (j['customer_rating'] as num).toDouble())
              .toList();
          final avg = ratings.reduce((a, b) => a + b) / ratings.length;
          await supabase.from('providers').update({
            'rating': double.parse(avg.toStringAsFixed(1)),
          }).eq('id', providerId);
        }
      }
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
      final data = await supabase
          .from('jobs')
          .select('*, addresses(*)')
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
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
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
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  Text('\$${job['final_price'] ?? job['base_price']}',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700)),
                ],
              ),
              if (photos.isNotEmpty) ...[
                const Divider(height: 24),
                const Text('Completion Photos',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
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
                      errorBuilder: (_, __, ___) =>
                          const Icon(Icons.broken_image),
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
                style: const TextStyle(color: Colors.grey, fontSize: 14)),
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
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Column(
                        children: [
                          const Text('Total Spent',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 14)),
                          const SizedBox(height: 4),
                          Text(
                            '\$$totalSpent',
                            style: TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: Colors.blue.shade700,
                            ),
                          ),
                          Text(
                            '${completedJobs.length} service${completedJobs.length == 1 ? '' : 's'}',
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
                                            Text(describeJob(job),
                                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                            const SizedBox(height: 2),
                                            if (job['addresses'] != null)
                                              Text(
                                                '${job['addresses']['address_line']}, ${job['addresses']['city']}',
                                                style: const TextStyle(color: Colors.grey, fontSize: 13),
                                              ),
                                            Text(formatDate(job['created_at']),
                                                style: const TextStyle(color: Colors.grey, fontSize: 13)),
                                          ],
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: () => showReceipt(job),
                                        child: Column(
                                          children: [
                                            Text('\$${job['final_price'] ?? job['base_price']}',
                                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.green.shade700)),
                                            const Text('Receipt', style: TextStyle(color: Colors.blue, fontSize: 12)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  const Divider(height: 1),
                                  const SizedBox(height: 10),
                                  if (rated == null) ...[
                                    const Text('How was your service?',
                                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
                                        Text('You rated this service',
                                            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
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
                ),
    );
  }
}
