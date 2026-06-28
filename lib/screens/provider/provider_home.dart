import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import '../../theme.dart';
import 'job_history_screen.dart';

final supabase = Supabase.instance.client;

const int _kDispatchSeconds = 240;

class ProviderHome extends StatefulWidget {
  const ProviderHome({super.key});

  @override
  State<ProviderHome> createState() => _ProviderHomeState();
}

class _ProviderHomeState extends State<ProviderHome> {
  bool isOnline = false;
  String? providerId;
  double? _rating;
  int? _totalJobs;
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
          .select('id, is_online, rating, total_jobs')
          .eq('user_id', supabase.auth.currentUser!.id)
          .limit(1);
      if (results.isEmpty) return;
      final data = results.first;
      if (mounted) {
        final pid = data['id'].toString();
        // Always start offline — stale online state from a previous session shouldn't carry over
        await supabase.from('providers').update({'is_online': false}).eq('id', pid);
        setState(() {
          providerId = pid;
          isOnline = false;
          _rating = (data['rating'] as num?)?.toDouble();
          _totalJobs = data['total_jobs'] as int?;
        });
        loadActiveJobs();
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

    final update = <String, dynamic>{'is_online': value};

    if (value) {
      try {
        LocationPermission permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission != LocationPermission.deniedForever) {
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
          ).timeout(const Duration(seconds: 8));
          update['current_lat'] = position.latitude;
          update['current_lng'] = position.longitude;
        }
      } catch (e) {
        debugPrint('Location error on toggle online: $e');
      }
    }

    await supabase.from('providers').update(update).eq('id', providerId!);

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
      final results = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('dispatched_to', providerId!)
          .eq('status', 'requested')
          .order('created_at')
          .limit(1);
      final data = results.isEmpty ? null : results.first as Map<String, dynamic>;
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
          .order('created_at', ascending: true);
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

      final activeJobs = await supabase
          .from('jobs')
          .select('provider_id, job_lat, job_lng')
          .inFilter('status', ['assigned', 'in_progress']);

      final Map<String, Map<String, dynamic>> providerActiveJob = {};
      for (final job in activeJobs as List) {
        final pid = job['provider_id']?.toString();
        if (pid != null) {
          providerActiveJob[pid] = (providerActiveJob[pid] == null)
              ? {'count': 1, 'job_lat': job['job_lat'], 'job_lng': job['job_lng']}
              : {'count': (providerActiveJob[pid]!['count'] as int) + 1, 'job_lat': job['job_lat'], 'job_lng': job['job_lng']};
        }
      }

      final available = (providers as List)
          .where((p) {
            if (rejected.contains(p['id'].toString())) return false;
            final activeCount = providerActiveJob[p['id'].toString()]?['count'] as int? ?? 0;
            return activeCount < 2;
          })
          .toList();

      if (available.isEmpty) return;

      if (lat != null && lng != null) {
        final jlat = (lat as num).toDouble();
        final jlng = (lng as num).toDouble();
        available.sort((a, b) {
          final aInfo = providerActiveJob[a['id'].toString()];
          final bInfo = providerActiveJob[b['id'].toString()];
          final aLat = (aInfo != null && aInfo['job_lat'] != null)
              ? (aInfo['job_lat'] as num).toDouble()
              : (a['current_lat'] ?? 0).toDouble();
          final aLng = (aInfo != null && aInfo['job_lng'] != null)
              ? (aInfo['job_lng'] as num).toDouble()
              : (a['current_lng'] ?? 0).toDouble();
          final bLat = (bInfo != null && bInfo['job_lat'] != null)
              ? (bInfo['job_lat'] as num).toDouble()
              : (b['current_lat'] ?? 0).toDouble();
          final bLng = (bInfo != null && bInfo['job_lng'] != null)
              ? (bInfo['job_lng'] as num).toDouble()
              : (b['current_lng'] ?? 0).toDouble();
          return _dist2(jlat, jlng, aLat, aLng).compareTo(_dist2(jlat, jlng, bLat, bLng));
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

  int _calcEtaMinutes(double provLat, double provLng, double jobLat, double jobLng) {
    const R = 6371.0;
    final dLat = (jobLat - provLat) * pi / 180;
    final dLng = (jobLng - provLng) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(provLat * pi / 180) * cos(jobLat * pi / 180) *
        sin(dLng / 2) * sin(dLng / 2);
    final distKm = R * 2 * atan2(sqrt(a), sqrt(1 - a));
    final minutes = (distKm / 30 * 60 * 1.3).round();
    // Round to nearest 5, minimum 5
    return max(60, ((minutes / 5).round() * 5));
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

  void _showAccountSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.email_outlined, color: SnowServColors.navy),
                title: const Text('Contact Support'),
                subtitle: const Text('support@snowserv.app'),
                onTap: () async {
                  Navigator.pop(context);
                  final uri = Uri(
                    scheme: 'mailto',
                    path: 'support@snowserv.app',
                    queryParameters: {'subject': 'SnowServ Provider Support Request'},
                  );
                  final launched = await launchUrl(uri);
                  if (!launched && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Email us at support@snowserv.app'),
                        duration: Duration(seconds: 5),
                      ),
                    );
                  }
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.red),
                title: const Text('Log Out', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(context);
                  if (providerId != null) {
                    await supabase.from('providers').update({'is_online': false}).eq('id', providerId!);
                  }
                  await supabase.auth.signOut();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _notifyCustomer(String jobId, String status) {
    supabase.functions.invoke('notify-customer', body: {'job_id': jobId, 'status': status});
  }

  Future<void> _launchNavigation(Map<String, dynamic> job) async {
    final addr = job['addresses'];
    if (addr == null) return;
    final destination = Uri.encodeComponent(
      '${addr['address_line']}, ${addr['city']}, ${addr['state']} ${addr['zip']}',
    );
    final appleMaps = Uri.parse('maps://maps.apple.com/?daddr=$destination');
    final googleMaps = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destination');
    if (await canLaunchUrl(appleMaps)) {
      await launchUrl(appleMaps);
    } else {
      await launchUrl(googleMaps, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> acceptJob(String jobId) async {
    if (providerId == null) return;
    _stopCountdown();
    final job = _dispatchedJob;
    setState(() => _dispatchedJob = null);
    try {
      int? eta;
      if (job != null && job['job_lat'] != null && job['job_lng'] != null) {
        final provData = await supabase
            .from('providers')
            .select('current_lat, current_lng')
            .eq('id', providerId!)
            .single();
        if (provData['current_lat'] != null && provData['current_lng'] != null) {
          eta = _calcEtaMinutes(
            (provData['current_lat'] as num).toDouble(),
            (provData['current_lng'] as num).toDouble(),
            (job['job_lat'] as num).toDouble(),
            (job['job_lng'] as num).toDouble(),
          );
        }
      }
      await supabase.from('jobs').update({
        'status': 'assigned',
        'provider_id': providerId,
        'dispatched_to': null,
        if (eta != null) 'eta_minutes': eta,
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

  Future<void> cancelAcceptedJob(String jobId, Map<String, dynamic> job) async {
    final inProgress = job['status'] == 'in_progress';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel This Job?'),
        content: Text(inProgress
            ? 'You have already started this job. Are you sure you need to cancel? The customer will be notified and we will find another provider.'
            : 'Are you sure you need to cancel? The customer will be notified and we will find another provider.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No, Keep Job'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Yes, Cancel'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final rejected = List<dynamic>.from(job['rejected_providers'] ?? []);
      rejected.add(providerId!);
      await supabase.from('jobs').update({
        'status': 'requested',
        'provider_id': null,
        'dispatched_to': null,
        'dispatched_at': null,
        'rejected_providers': rejected,
      }).eq('id', jobId);
      supabase.functions.invoke('notify-customer', body: {'job_id': jobId, 'status': 'provider_cancelled'});
      await _redispatch(jobId, rejected, job['job_lat'], job['job_lng']);
      loadActiveJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job returned to queue. Another provider will be assigned.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
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

      // Fetch next queued job before refreshing state
      final remaining = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('provider_id', providerId!)
          .inFilter('status', ['assigned', 'in_progress'])
          .order('created_at')
          .limit(1);

      loadActiveJobs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job marked as complete!')),
        );
        if (remaining.isNotEmpty) {
          _launchNavigation(Map<String, dynamic>.from(remaining.first));
        }
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
            if (job['customer_notes'] != null && '${job['customer_notes']}'.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade800.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.notes_outlined, color: Colors.white70, size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${job['customer_notes']}',
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
          TextButton.icon(
            icon: const Icon(Icons.receipt_long, color: Colors.white, size: 18),
            label: const Text('My Jobs', style: TextStyle(color: Colors.white)),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const JobHistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Account',
            onPressed: () => _showAccountSheet(),
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
                color: Colors.transparent,
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
              child: Material(
                color: isOnline ? const Color(0xFFE8F5E9) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(14),
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
            ),
            if (_rating != null || _totalJobs != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: SnowServColors.glacier),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 20),
                        const SizedBox(width: 6),
                        Text(
                          _rating != null ? _rating!.toStringAsFixed(1) : '—',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: SnowServColors.navy,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Your Rating',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check_circle_outline, color: SnowServColors.iceBlue, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          '${_totalJobs ?? 0} jobs done',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
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
                                    Flexible(
                                      child: Text(describeJob(job),
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              color: SnowServColors.navy)),
                                    ),
                                    const SizedBox(width: 8),
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
                                if (job['customer_notes'] != null && '${job['customer_notes']}'.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade50,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.blue.shade200),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.notes_outlined, color: Colors.blue.shade400, size: 14),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            '${job['customer_notes']}',
                                            style: const TextStyle(fontSize: 13, color: Colors.black87),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
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
                                    const SizedBox(width: 8),
                                    OutlinedButton(
                                      onPressed: () => cancelAcceptedJob(job['id'].toString(), job),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red,
                                        side: const BorderSide(color: Colors.red),
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                                      ),
                                      child: const Text('Cancel'),
                                    ),
                                  ],
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
