import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:async';
import 'dart:io';
import '../../theme.dart';
import 'job_history_screen.dart';

final supabase = Supabase.instance.client;

const int _kDispatchSeconds = 180;

class ProviderHome extends StatefulWidget {
  const ProviderHome({super.key});

  @override
  State<ProviderHome> createState() => _ProviderHomeState();
}

class _ProviderHomeState extends State<ProviderHome> {
  bool isOnline = false;
  String? providerId;
  Map<String, dynamic>? _dispatchedJob;
  List<Map<String, dynamic>> activeJobs = [];
  bool loading = false;
  RealtimeChannel? _jobsChannel;
  Timer? _countdownTimer;
  int _secondsRemaining = _kDispatchSeconds;
  bool _declining = false;

  @override
  void initState() {
    super.initState();
    loadProviderRecord();
  }

  @override
  void dispose() {
    _jobsChannel?.unsubscribe();
    _stopCountdown();
    super.dispose();
  }

  void subscribeToJobs() {
    _jobsChannel = supabase.channel('provider_jobs').onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'jobs',
      callback: (payload) {
        final newRecord = payload.newRecord;
        if (newRecord['status'] == 'cancelled' &&
            newRecord['provider_id'] == providerId) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('The customer cancelled this job.'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        loadDispatchedJob();
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
        if (isOnline) loadDispatchedJob();
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
      if (!value) {
        _dispatchedJob = null;
        _stopCountdown();
      }
    });
    if (value) {
      loadDispatchedJob();
      _checkAndDispatchWaitingJob();
    }
  }

  Future<void> loadDispatchedJob() async {
    if (providerId == null) return;
    setState(() => loading = true);
    try {
      final data = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('dispatched_to', providerId!)
          .eq('status', 'requested')
          .maybeSingle();
      if (mounted) {
        final prev = _dispatchedJob;
        setState(() => _dispatchedJob = data);
        if (data != null && (prev == null || prev['id'] != data['id'])) {
          _startCountdown(data);
        } else if (data == null) {
          _stopCountdown();
        }
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

  void _startCountdown(Map<String, dynamic> job) {
    _stopCountdown();
    final dispatchedAt = DateTime.parse(job['dispatched_at']).toLocal();
    final elapsed = DateTime.now().difference(dispatchedAt).inSeconds;
    _secondsRemaining = (_kDispatchSeconds - elapsed).clamp(0, _kDispatchSeconds);
    if (_secondsRemaining == 0) {
      _declineJob();
      return;
    }
    setState(() {});
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsRemaining > 0) _secondsRemaining--;
      });
      if (_secondsRemaining <= 0) {
        _stopCountdown();
        _declineJob();
      }
    });
  }

  void _stopCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  Future<void> _declineJob() async {
    if (_declining || _dispatchedJob == null || providerId == null) return;
    _declining = true;
    _stopCountdown();
    final job = _dispatchedJob!;
    setState(() => _dispatchedJob = null);

    final jobId = job['id'].toString();
    final rejected = List<dynamic>.from(job['rejected_providers'] ?? []);
    rejected.add(providerId!);

    try {
      await supabase.from('jobs').update({
        'dispatched_to': null,
        'dispatched_at': null,
        'rejected_providers': rejected,
      }).eq('id', jobId);
      await _redispatch(jobId, rejected, job['job_lat'], job['job_lng']);
    } catch (e) {
      debugPrint('Decline error: $e');
    } finally {
      _declining = false;
    }
  }

  Future<void> _redispatch(String jobId, List<dynamic> rejected, dynamic lat, dynamic lng) async {
    try {
      final providers = await supabase
          .from('providers')
          .select('id, current_lat, current_lng')
          .eq('is_online', true)
          .eq('registration_status', 'approved');
      final available = (providers as List)
          .where((p) => !rejected.contains(p['id'].toString()))
          .toList();
      if (available.isEmpty) return;
      if (lat != null && lng != null) {
        final jlat = (lat as num).toDouble();
        final jlng = (lng as num).toDouble();
        available.sort((a, b) {
          final da = _dist2(jlat, jlng, (a['current_lat'] ?? 0).toDouble(), (a['current_lng'] ?? 0).toDouble());
          final db = _dist2(jlat, jlng, (b['current_lat'] ?? 0).toDouble(), (b['current_lng'] ?? 0).toDouble());
          return da.compareTo(db);
        });
      }
      await supabase.from('jobs').update({
        'dispatched_to': available.first['id'],
        'dispatched_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', jobId);
    } catch (e) {
      debugPrint('Redispatch error: $e');
    }
  }

  double _dist2(double lat1, double lng1, double lat2, double lng2) {
    final dlat = lat2 - lat1;
    final dlng = (lng2 - lng1) * 0.7;
    return dlat * dlat + dlng * dlng;
  }

  Future<void> _checkAndDispatchWaitingJob() async {
    if (providerId == null) return;
    try {
      final waiting = await supabase
          .from('jobs')
          .select('id, job_lat, job_lng, rejected_providers')
          .eq('status', 'requested')
          .isFilter('dispatched_to', null)
          .order('created_at')
          .limit(1);
      if (waiting.isEmpty) return;
      final job = (waiting as List).first;
      final rejected = List<dynamic>.from(job['rejected_providers'] ?? []);
      if (rejected.contains(providerId!)) return;
      await supabase.from('jobs').update({
        'dispatched_to': providerId,
        'dispatched_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', job['id']);
      loadDispatchedJob();
    } catch (e) {
      debugPrint('Check waiting job error: $e');
    }
  }

  void _notifyCustomer(String jobId, String status) {
    supabase.functions.invoke('notify-customer', body: {'job_id': jobId, 'status': status});
  }

  Future<void> acceptJob(String jobId) async {
    if (providerId == null) return;
    _stopCountdown();
    setState(() => _dispatchedJob = null);
    try {
      await supabase.from('jobs').update({
        'status': 'assigned',
        'provider_id': providerId,
        'dispatched_to': null,
      }).eq('id', jobId);
      _notifyCustomer(jobId, 'assigned');
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
      await supabase.from('jobs').update({'status': 'in_progress'}).eq('id', jobId);
      _notifyCustomer(jobId, 'in_progress');
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
                            setDialogState(() => selectedPhotos.add(File(photo.path)));
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
                          final photos = await picker.pickMultiImage(imageQuality: 75);
                          if (photos.isNotEmpty) {
                            setDialogState(() => selectedPhotos.addAll(photos.map((p) => File(p.path))));
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
                              onTap: () => setDialogState(() => selectedPhotos.removeAt(i)),
                              child: const CircleAvatar(
                                radius: 10,
                                backgroundColor: Colors.red,
                                child: Icon(Icons.close, size: 12, color: Colors.white),
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
          final fileName = 'job_${jobId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await supabase.storage.from('job-photos').upload(fileName, photo);
          final url = supabase.storage.from('job-photos').getPublicUrl(fileName);
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

      _notifyCustomer(jobId, 'completed');
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

  String providerPay(Map<String, dynamic> job) {
    final total = (job['final_price'] ?? job['base_price'] ?? 0) as num;
    return (total * 0.70).round().toString();
  }

  Widget _addressRow(Map<String, dynamic> job, {Color color = Colors.grey}) {
    if (job['addresses'] == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Icon(Icons.location_on, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '${job['addresses']['address_line']}, ${job['addresses']['city']}, ${job['addresses']['state']} ${job['addresses']['zip']}',
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDispatchCard() {
    final job = _dispatchedJob!;
    final isUrgent = _secondsRemaining < 60;
    final minutes = _secondsRemaining ~/ 60;
    final seconds = _secondsRemaining % 60;
    final timerStr = '$minutes:${seconds.toString().padLeft(2, '0')}';
    final fraction = (_secondsRemaining / _kDispatchSeconds).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isUrgent
              ? [Colors.red.shade700, Colors.red.shade500]
              : [Colors.orange.shade700, Colors.orange.shade500],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: (isUrgent ? Colors.red : Colors.orange).withOpacity(0.4),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'NEW JOB REQUEST',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  timerStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              describeJob(job),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            _addressRow(job, color: Colors.white70),
            const SizedBox(height: 6),
            Text(
              'Your pay: \$${providerPay(job)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _declining ? null : _declineJob,
                    icon: const Icon(Icons.close, color: Colors.white, size: 16),
                    label: const Text('Decline',
                        style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => acceptJob(job['id'].toString()),
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Accept'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: isUrgent
                          ? Colors.red.shade700
                          : Colors.orange.shade700,
                      padding: const EdgeInsets.symmetric(vertical: 13),
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

  @override
  Widget build(BuildContext context) {
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
          TextButton(
            onPressed: () => supabase.auth.signOut(),
            child: const Text('Log Out', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Online toggle
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
                    ? [BoxShadow(
                        color: Colors.green.withOpacity(0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 3))]
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
                  isOnline
                      ? 'You are visible to customers'
                      : 'Toggle on to start receiving jobs',
                  style: TextStyle(
                    fontSize: 12,
                    color: isOnline ? Colors.green.shade600 : Colors.grey,
                  ),
                ),
                value: isOnline,
                activeColor: Colors.green,
                onChanged: providerId != null ? toggleOnline : null,
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Dispatched job timer card
                    if (_dispatchedJob != null) _buildDispatchCard(),

                    // Active jobs
                    if (activeJobs.isNotEmpty) ...[
                      const Text('Active Jobs',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: SnowServColors.navy)),
                      const SizedBox(height: 8),
                      ...activeJobs.map((job) {
                        final inProgress = job['status'] == 'in_progress';
                        return Card(
                          color: inProgress
                              ? const Color(0xFFE8F5E9)
                              : const Color(0xFFE3F2FD),
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
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
                                            fontSize: 16,
                                            color: SnowServColors.navy)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: inProgress
                                            ? Colors.green
                                            : SnowServColors.iceBlue,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        inProgress ? 'In Progress' : 'Assigned',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                _addressRow(job),
                                Text(
                                  'Your pay: \$${providerPay(job)}',
                                  style: const TextStyle(
                                      fontSize: 20,
                                      color: Colors.green,
                                      fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: inProgress
                                      ? ElevatedButton.icon(
                                          onPressed: () =>
                                              completeJob(job['id'].toString()),
                                          icon: const Icon(
                                              Icons.check_circle_outline),
                                          label: const Text('Complete Job'),
                                          style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.green),
                                        )
                                      : ElevatedButton.icon(
                                          onPressed: () =>
                                              markInProgress(job['id'].toString()),
                                          icon: const Icon(Icons.play_arrow),
                                          label: const Text('Start Job'),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 8),
                    ],

                    // Idle state
                    if (!isOnline)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 48),
                          child: Column(
                            children: [
                              Icon(Icons.power_settings_new,
                                  size: 56, color: Colors.grey.shade300),
                              const SizedBox(height: 12),
                              Text('Go online to receive jobs',
                                  style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 16)),
                            ],
                          ),
                        ),
                      )
                    else if (loading)
                      const Center(
                          child: Padding(
                        padding: EdgeInsets.only(top: 48),
                        child: CircularProgressIndicator(),
                      ))
                    else if (_dispatchedJob == null && activeJobs.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 48),
                          child: Column(
                            children: [
                              Icon(Icons.hourglass_empty,
                                  size: 56, color: Colors.grey.shade300),
                              const SizedBox(height: 12),
                              Text('Waiting for jobs...',
                                  style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 16)),
                              const SizedBox(height: 4),
                              Text('You\'ll be notified when a job is dispatched to you',
                                  style: TextStyle(
                                      color: Colors.grey.shade400,
                                      fontSize: 13),
                                  textAlign: TextAlign.center),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
