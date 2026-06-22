import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import '../../theme.dart';
import 'job_history_screen.dart';

final supabase = Supabase.instance.client;

class ProviderHome extends StatefulWidget {
  const ProviderHome({super.key});

  @override
  State<ProviderHome> createState() => _ProviderHomeState();
}

class _ProviderHomeState extends State<ProviderHome> {
  bool isOnline = false;
  String? providerId;
  List<Map<String, dynamic>> availableJobs = [];
  List<Map<String, dynamic>> activeJobs = [];
  Set<String> rejectedJobIds = {};
  bool loading = false;
  RealtimeChannel? _jobsChannel;

  @override
  void initState() {
    super.initState();
    loadProviderRecord();
  }

  @override
  void dispose() {
    _jobsChannel?.unsubscribe();
    super.dispose();
  }

  void subscribeToJobs() {
    _jobsChannel = supabase.channel('provider_jobs').onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'jobs',
      callback: (payload) {
        loadJobs();
        loadActiveJobs();
      },
    ).subscribe();
  }

  Future<void> loadProviderRecord() async {
    try {
      final results = await supabase
          .from('providers')
          .select('id, is_online')
          .eq('user_id', supabase.auth.currentUser!.id)
          .limit(1);
      if (results.isEmpty) return;
      final data = results.first;
      if (mounted) {
        setState(() {
          providerId = data['id'].toString();
          isOnline = data['is_online'] ?? false;
        });
        loadActiveJobs();
        if (isOnline) loadJobs();
        subscribeToJobs();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading provider profile: $e')),
        );
      }
    }
  }

  Future<void> toggleOnline(bool value) async {
    if (providerId == null) return;
    await supabase
        .from('providers')
        .update({'is_online': value})
        .eq('id', providerId!);
    setState(() {
      isOnline = value;
      if (!value) availableJobs = [];
    });
    if (value) loadJobs();
  }

  Future<void> loadJobs() async {
    setState(() => loading = true);
    try {
      final data = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('status', 'requested')
          .order('created_at');
      if (mounted) {
        setState(() => availableJobs = List<Map<String, dynamic>>.from(data));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadActiveJobs() async {
    if (providerId == null) return;
    try {
      final data = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('provider_id', providerId!)
          .inFilter('status', ['assigned', 'in_progress'])
          .order('created_at');
      if (mounted) {
        setState(() => activeJobs = List<Map<String, dynamic>>.from(data));
      }
    } catch (_) {}
  }

  void rejectJob(String jobId) {
    setState(() => rejectedJobIds.add(jobId));
  }

  Future<void> acceptJob(String jobId) async {
    if (providerId == null) return;
    try {
      await supabase.from('jobs').update({
        'status': 'assigned',
        'provider_id': providerId,
      }).eq('id', jobId);
      loadJobs();
      loadActiveJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job accepted!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> markInProgress(String jobId) async {
    try {
      await supabase.from('jobs').update({
        'status': 'in_progress',
      }).eq('id', jobId);
      loadActiveJobs();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> completeJob(String jobId) async {
    final notesController = TextEditingController();
    final List<File> selectedPhotos = [];
    final picker = ImagePicker();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Complete Job'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Add photos of the completed work:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Camera'),
                        onPressed: () async {
                          final photo = await picker.pickImage(
                            source: ImageSource.camera,
                            imageQuality: 75,
                          );
                          if (photo != null) {
                            setDialogState(() =>
                                selectedPhotos.add(File(photo.path)));
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.photo_library),
                        label: const Text('Gallery'),
                        onPressed: () async {
                          final photos = await picker.pickMultiImage(
                            imageQuality: 75,
                          );
                          if (photos.isNotEmpty) {
                            setDialogState(() => selectedPhotos
                                .addAll(photos.map((p) => File(p.path))));
                          }
                        },
                      ),
                    ),
                  ],
                ),
                if (selectedPhotos.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: selectedPhotos.length,
                      itemBuilder: (context, i) => Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(selectedPhotos[i],
                                  width: 80, height: 80, fit: BoxFit.cover),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            right: 4,
                            child: GestureDetector(
                              onTap: () => setDialogState(
                                  () => selectedPhotos.removeAt(i)),
                              child: const CircleAvatar(
                                radius: 10,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close,
                                    size: 12, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Notes for admin (optional):',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: notesController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Job underpriced, heavy snow, access issues...',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Mark Complete'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      List<String> photoUrls = [];

      if (selectedPhotos.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Uploading photos...')),
          );
        }
        for (final photo in selectedPhotos) {
          final fileName =
              'job_${jobId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await supabase.storage
              .from('job-photos')
              .upload(fileName, photo);
          final url = supabase.storage
              .from('job-photos')
              .getPublicUrl(fileName);
          photoUrls.add(url);
        }
      }

      await supabase.from('jobs').update({
        'status': 'completed',
        'provider_notes': notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim(),
        if (photoUrls.isNotEmpty) 'completion_photos': photoUrls,
      }).eq('id', jobId);

      loadActiveJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job marked as complete!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  String describeJob(Map<String, dynamic> job) {
    final List<String> services = [];
    if (job['driveway'] == true) services.add('Driveway');
    if (job['walkway'] == true) services.add('Sidewalk');
    if (job['salting'] == true) services.add('Salting');
    return services.isEmpty ? 'Service' : services.join(' + ');
  }

  Widget _addressRow(Map<String, dynamic> job) {
    if (job['addresses'] == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          const Icon(Icons.location_on, size: 14, color: SnowServColors.iceBluLight),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${job['addresses']['address_line']}, ${job['addresses']['city']}, ${job['addresses']['state']} ${job['addresses']['zip']}',
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleJobs = availableJobs
        .where((j) => !rejectedJobIds.contains(j['id'].toString()))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Text('❄  SnowServ', style: TextStyle(letterSpacing: 1)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Job History',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const JobHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isOnline ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isOnline ? Colors.green : Colors.grey.shade300,
                  width: 2,
                ),
                boxShadow: isOnline
                    ? [BoxShadow(color: Colors.green.withOpacity(0.15), blurRadius: 8, offset: const Offset(0, 3))]
                    : [],
              ),
              child: SwitchListTile(
                title: Text(
                  isOnline ? '🟢  Online — accepting jobs' : '⚫  Offline',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: isOnline ? Colors.green.shade800 : Colors.grey.shade600,
                  ),
                ),
                subtitle: Text(
                  isOnline ? 'You are visible to customers' : 'Toggle on to start receiving jobs',
                  style: TextStyle(fontSize: 12, color: isOnline ? Colors.green.shade600 : Colors.grey),
                ),
                value: isOnline,
                activeColor: Colors.green,
                onChanged: providerId != null ? toggleOnline : null,
              ),
            ),
            const SizedBox(height: 16),

            if (activeJobs.isNotEmpty) ...[
              const Text('Active Jobs',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
              const SizedBox(height: 8),
              ...activeJobs.map((job) {
                final inProgress = job['status'] == 'in_progress';
                return Card(
                  color: inProgress ? const Color(0xFFE8F5E9) : const Color(0xFFE3F2FD),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(describeJob(job),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: SnowServColors.navy)),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: inProgress ? Colors.green : SnowServColors.iceBlue,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                inProgress ? 'In Progress' : 'Assigned',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        _addressRow(job),
                        Text('\$${job['base_price']}',
                            style: const TextStyle(fontSize: 20, color: Colors.green, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: inProgress
                              ? ElevatedButton.icon(
                                  onPressed: () => completeJob(job['id'].toString()),
                                  icon: const Icon(Icons.check_circle_outline),
                                  label: const Text('Complete Job'),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                                )
                              : ElevatedButton.icon(
                                  onPressed: () => markInProgress(job['id'].toString()),
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('Start Job'),
                                ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const Divider(height: 20),
            ],

            if (isOnline) ...[
              const Text('Available Jobs',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
              const SizedBox(height: 8),
            ],

            if (!isOnline)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.power_settings_new, size: 56, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text('Go online to see available jobs',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                    ],
                  ),
                ),
              )
            else if (loading)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (visibleJobs.isEmpty)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off, size: 56, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text('No new jobs available right now',
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 16)),
                    ],
                  ),
                ),
              )
            else
              Expanded(
                child: RefreshIndicator(
                  onRefresh: loadJobs,
                  child: ListView.builder(
                    itemCount: visibleJobs.length,
                    itemBuilder: (context, index) {
                      final job = visibleJobs[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(describeJob(job),
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: SnowServColors.navy)),
                                  Text('\$${job['base_price']}',
                                      style: const TextStyle(fontSize: 20, color: Colors.green, fontWeight: FontWeight.bold)),
                                ],
                              ),
                              _addressRow(job),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => rejectJob(job['id'].toString()),
                                      icon: const Icon(Icons.close, size: 16),
                                      label: const Text('Reject'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red,
                                        side: const BorderSide(color: Colors.red),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => acceptJob(job['id'].toString()),
                                      icon: const Icon(Icons.check, size: 16),
                                      label: const Text('Accept'),
                                    ),
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
              ),
          ],
        ),
      ),
    );
  }
}
