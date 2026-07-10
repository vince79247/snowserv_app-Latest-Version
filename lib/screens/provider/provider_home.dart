import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import '../../theme.dart';
import '../../utils/job_helpers.dart';
import '../../utils/dispatch.dart';
import '../../utils/legal.dart';
import 'job_history_screen.dart';
import 'provider_agreement_screen.dart';
import 'provider_details_screen.dart';
import 'provider_tax_info_screen.dart';
import '../faq_screen.dart';
import '../edit_profile_screen.dart';
import '../admin/admin_screen.dart';
import '../../utils/web_layout.dart';

final supabase = Supabase.instance.client;

const int _kDispatchSeconds = 240;

class ProviderHome extends StatefulWidget {
  const ProviderHome({super.key});

  @override
  State<ProviderHome> createState() => _ProviderHomeState();
}

class _ProviderHomeState extends State<ProviderHome> with WidgetsBindingObserver {
  bool isOnline = false;
  String? providerId;
  double? _rating;
  int? _totalJobs;
  Map<String, dynamic>? _dispatchedJob;
  List<Map<String, dynamic>> activeJobs = [];
  // Jobs sitting in the queue with no provider currently holding an offer —
  // shown as a "Jobs Waiting" board so any on-duty provider can grab one,
  // including a job they previously declined (a second shot).
  List<Map<String, dynamic>> _waitingJobs = [];
  bool loading = false;
  RealtimeChannel? _jobsChannel;
  StreamSubscription? _fcmSub;
  Timer? _countdownTimer;
  int _secondsRemaining = _kDispatchSeconds;
  bool _declining = false;
  bool _isAdmin = false;
  bool _autoAccept = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadProviderRecord();
    _loadIsAdmin();
    // Realtime is the primary refresh path, but websockets can drop. Any push
    // (dispatch, cancel, etc.) also refreshes the board so a cancelled job
    // can't linger on the dashboard.
    _fcmSub = FirebaseMessaging.onMessage.listen((_) => _refreshBoard());
  }

  void _refreshBoard() {
    loadDispatchedJob();
    loadActiveJobs();
    loadWaitingJobs();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // While the app is backgrounded (e.g. the provider is in Apple Maps after
    // accepting a job) realtime and FCM onMessage are suspended, so a job
    // cancelled meanwhile is missed. Refresh the board on return so it clears.
    if (state == AppLifecycleState.resumed) _refreshBoard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _jobsChannel?.unsubscribe();
    _fcmSub?.cancel();
    _stopCountdown();
    super.dispose();
  }

  Future<void> _loadIsAdmin() async {
    try {
      final data = await supabase
          .from('profiles')
          .select('is_admin')
          .eq('id', supabase.auth.currentUser!.id)
          .maybeSingle();
      if (mounted && data?['is_admin'] == true) setState(() => _isAdmin = true);
    } catch (_) {}
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
        loadWaitingJobs();
      },
    ).subscribe();
  }

  Future<void> loadProviderRecord() async {
    try {
      final results = await supabase
          .from('providers')
          .select('id, is_online, rating, total_jobs, auto_accept')
          .eq('user_id', supabase.auth.currentUser!.id)
          .limit(1);
      if (results.isEmpty) return;
      final data = results.first;
      if (mounted) {
        final pid = data['id'].toString();
        final wasOnline = data['is_online'] == true;
        setState(() {
          providerId = pid;
          isOnline = wasOnline;
          _rating = (data['rating'] as num?)?.toDouble();
          _totalJobs = data['total_jobs'] as int?;
          _autoAccept = data['auto_accept'] == true;
        });
        loadActiveJobs();
        if (wasOnline) {
          loadDispatchedJob();
          loadWaitingJobs();
        }
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

  Future<void> _toggleAutoAccept(bool value) async {
    if (providerId == null) return;
    setState(() => _autoAccept = value);
    try {
      await supabase.from('providers').update({'auto_accept': value}).eq('id', providerId!);
    } catch (e) {
      if (mounted) {
        setState(() => _autoAccept = !value); // revert on failure
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update auto-accept: $e')),
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
        _waitingJobs = [];
        _stopCountdown();
      }
    });

    if (value) {
      loadDispatchedJob();
      _checkAndDispatchWaitingJob();
      loadWaitingJobs();
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
      final data = results.isEmpty ? null : results.first;
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
          // Join the customer so the provider can call them (gate, dog, etc.).
          .select('*, addresses(*), users!jobs_customer_id_fkey(name, phone)')
          .eq('provider_id', providerId!)
          .inFilter('status', ['assigned', 'in_progress'])
          .order('created_at', ascending: true);
      if (mounted) {
        setState(() => activeJobs = List<Map<String, dynamic>>.from(data));
      }
    } catch (_) {}
  }

  // Jobs that are queued (requested) but not currently pushed to anyone —
  // i.e. no one holds a live dispatch offer. These are grabbable by any
  // on-duty provider, so a driver who changed their mind gets a second shot.
  Future<void> loadWaitingJobs() async {
    if (providerId == null || !isOnline) {
      if (mounted && _waitingJobs.isNotEmpty) setState(() => _waitingJobs = []);
      return;
    }
    try {
      final data = await supabase
          .from('jobs')
          .select('*, addresses(*)')
          .eq('status', 'requested')
          .isFilter('dispatched_to', null)
          .order('created_at', ascending: true);
      if (mounted) {
        setState(() =>
            _waitingJobs = List<Map<String, dynamic>>.from(data as List));
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
      await dispatchToNearest(supabase, jobId, rejected,
          (job['job_lat'] as num?)?.toDouble(), (job['job_lng'] as num?)?.toDouble());
    } catch (e) {
      debugPrint('Decline error: $e');
    } finally {
      _declining = false;
    }
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
    // Round to nearest 5, minimum 60
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

  Future<void> _editBankingDetails() async {
    if (providerId == null) return;
    final routingController = TextEditingController();
    final accountController = TextEditingController();

    // Pre-fill existing values
    try {
      final data = await supabase
          .from('providers')
          .select('bank_routing, bank_account')
          .eq('id', providerId!)
          .single();
      routingController.text = data['bank_routing'] ?? '';
      accountController.text = data['bank_account'] ?? '';
    } catch (_) {}

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.account_balance_outlined, color: SnowServColors.navy),
            SizedBox(width: 8),
            Text('Banking Details'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your banking information is used for payouts only and stored securely.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: routingController,
              keyboardType: TextInputType.number,
              maxLength: 9,
              decoration: const InputDecoration(
                labelText: 'Routing Number',
                hintText: '9-digit routing number',
                prefixIcon: Icon(Icons.numbers),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: accountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Account Number',
                prefixIcon: Icon(Icons.credit_card),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final routing = routingController.text.trim();
              final account = accountController.text.trim();
              if (routing.length != 9) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Routing number must be 9 digits.')),
                );
                return;
              }
              if (account.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter your account number.')),
                );
                return;
              }
              try {
                await supabase.from('providers').update({
                  'bank_routing': routing,
                  'bank_account': account,
                }).eq('id', providerId!);
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Banking details updated successfully.'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error saving: $e')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    routingController.dispose();
    accountController.dispose();
  }

  void _showAccountSheet() {
    showModalBottomSheet(
      context: context,
      // Scrollable with a max height so the menu can never bottom-overflow as
      // entries accumulate (Admin Panel row, agreement, legal links...).
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
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
              if (_isAdmin) ...[
                ListTile(
                  leading: const Icon(Icons.admin_panel_settings, color: SnowServColors.iceBlue),
                  title: const Text('Admin Panel'),
                  onTap: () {
                    Navigator.pop(context);
                    openAdminPanel(context, const AdminPanelScreen());
                  },
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
              ],
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
                leading: const Icon(Icons.badge_outlined, color: SnowServColors.navy),
                title: const Text('My Info'),
                subtitle: const Text('Edit your name & phone'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const EditProfileScreen()));
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.directions_car_outlined, color: SnowServColors.navy),
                title: const Text('Vehicle & Insurance'),
                subtitle: const Text('Update your vehicle, deicer & insurance'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ProviderDetailsScreen()));
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.account_balance_outlined, color: SnowServColors.navy),
                title: const Text('Update Banking Details'),
                subtitle: const Text('Routing & account number for payouts'),
                onTap: () {
                  Navigator.pop(context);
                  _editBankingDetails();
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined, color: SnowServColors.navy),
                title: const Text('Tax Info (for 1099)'),
                subtitle: const Text('Name, tax ID & address for your 1099'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ProviderTaxInfoScreen()));
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.help_outline, color: SnowServColors.navy),
                title: const Text('Help & FAQ'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const FaqScreen()));
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ...legalMenuTiles(context),
              ListTile(
                leading: const Icon(Icons.assignment_outlined, color: SnowServColors.navy),
                title: const Text('Provider Service Agreement'),
                trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const ProviderAgreementScreen()));
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
    // Universal https link opens the Apple Maps app directly on iOS without
    // needing the maps:// scheme whitelisted in Info.plist. Fall back to
    // Google Maps if that fails for any reason.
    final appleMaps = Uri.parse('https://maps.apple.com/?daddr=$destination');
    final googleMaps = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destination');
    try {
      final ok = await launchUrl(appleMaps, mode: LaunchMode.externalApplication);
      if (!ok) {
        await launchUrl(googleMaps, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
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
      // Payment stays on HOLD at accept — it's captured when the provider
      // starts the job (see markInProgress). Cancelling before start releases
      // the hold, so the customer is never charged for a no-show.
      _notifyCustomer(jobId, 'assigned');
      loadActiveJobs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job accepted!')),
        );
      }

      // Open navigation to the accepted job — but only if the driver isn't
      // already working another job. If they are mid-job, we don't yank them
      // out to the map; it will open for this job when they complete the
      // current one (see completeJob's next-job navigation).
      if (job != null && mounted) {
        try {
          final inProgress = await supabase
              .from('jobs')
              .select('id')
              .eq('provider_id', providerId!)
              .eq('status', 'in_progress')
              .limit(1);
          if (inProgress.isEmpty && mounted) {
            _launchNavigation(Map<String, dynamic>.from(job));
          }
        } catch (e) {
          debugPrint('Accept-time navigation check failed: $e');
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

  // Claim a job off the "Jobs Waiting" board. Unlike a pushed dispatch, this
  // is provider-initiated, so it works even for a job this provider declined
  // earlier (we drop them from the rejected list). The conditional update is
  // atomic — only the first provider to grab an unclaimed job wins.
  Future<void> claimWaitingJob(Map<String, dynamic> job) async {
    if (providerId == null) return;
    final jobId = job['id'].toString();
    try {
      final rejected = List<dynamic>.from(job['rejected_providers'] ?? [])
        ..removeWhere((id) => id.toString() == providerId);

      int? eta;
      if (job['job_lat'] != null && job['job_lng'] != null) {
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

      final updated = await supabase
          .from('jobs')
          .update({
            'status': 'assigned',
            'provider_id': providerId,
            'dispatched_to': null,
            'dispatched_at': null,
            'rejected_providers': rejected,
            if (eta != null) 'eta_minutes': eta,
          })
          .eq('id', jobId)
          .eq('status', 'requested')
          .isFilter('dispatched_to', null)
          .select();

      if (updated.isEmpty) {
        // Lost the race — someone else grabbed it or it got dispatched.
        loadWaitingJobs();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That job was just taken by another provider.')),
          );
        }
        return;
      }

      // Payment stays on HOLD at accept — captured when the provider starts the
      // job (markInProgress), so cancelling before start never charges the card.
      _notifyCustomer(jobId, 'assigned');
      if (mounted) {
        setState(() => _waitingJobs
            .removeWhere((j) => j['id'].toString() == jobId));
      }
      loadActiveJobs();
      loadWaitingJobs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job accepted!')),
        );
      }

      // Open navigation unless already mid-another-job (same rule as Accept).
      try {
        final inProgress = await supabase
            .from('jobs')
            .select('id')
            .eq('provider_id', providerId!)
            .eq('status', 'in_progress')
            .limit(1);
        if (inProgress.isEmpty && mounted) {
          _launchNavigation(Map<String, dynamic>.from(job));
        }
      } catch (e) {
        debugPrint('Claim navigation check failed: $e');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
            // Post-start the customer's card has already been charged (Start
            // captures the hold). The charge stays; the job re-dispatches paid.
            ? 'You have already STARTED this job, so the customer has been charged. '
              'The job will be reassigned to another provider to finish. '
              'Cancelling after starting is recorded on your account — only do this '
              'if you truly cannot finish (e.g. equipment failure).'
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
      if (inProgress) {
        // Post-start cancel: the charge stays with the job (capture already
        // happened; re-capture on the next Start is idempotent). Count it on
        // this provider for admin visibility — best-effort, never blocks the
        // cancel itself.
        try {
          await supabase.rpc('increment_post_start_cancel',
              params: {'p_provider_id': providerId});
        } catch (_) {}
      }
      // Distinct status post-start so the customer push can be honest about
      // the charge ("you won't be charged again / cancel for a full refund").
      supabase.functions.invoke('notify-customer', body: {
        'job_id': jobId,
        'status': inProgress ? 'provider_cancelled_after_start' : 'provider_cancelled',
      });
      await dispatchToNearest(supabase, jobId, rejected,
          (job['job_lat'] as num?)?.toDouble(), (job['job_lng'] as num?)?.toDouble());
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
      // Guard against a stale card: if the customer cancelled (or the job
      // otherwise moved on) but the dashboard hadn't refreshed, don't start it
      // — that would flip a cancelled job to in_progress and try to charge.
      final current =
          await supabase.from('jobs').select('status').eq('id', jobId).maybeSingle();
      final status = current?['status'] as String?;
      if (status != 'assigned') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(status == 'cancelled'
                ? 'The customer cancelled this job.'
                : 'This job is no longer available.'),
            backgroundColor: Colors.red,
          ));
        }
        loadActiveJobs();
        loadDispatchedJob();
        loadWaitingJobs();
        return;
      }
      await supabase.from('jobs').update({'status': 'in_progress'}).eq('id', jobId);
      // The provider has started work — NOW capture the customer's held payment.
      // (Idempotent; a no-op if it was somehow already captured.)
      try {
        await supabase.functions.invoke('capture-payment', body: {'job_id': jobId});
      } catch (e) {
        debugPrint('Capture failed for $jobId: $e');
      }
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
                const Text('Photos of completed work are required:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                const Text('You must upload at least one photo to mark this job complete.',
                    style: TextStyle(fontSize: 12, color: Colors.red)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Camera'),
                        onPressed: () async {
                          // maxWidth/maxHeight downsize the image at the native
                          // layer, drastically cutting the memory a full-res
                          // camera capture uses. Without this, iOS may kill the
                          // app while the camera is open (blank white screen on
                          // return, lost photo).
                          final photo = await picker.pickImage(
                            source: ImageSource.camera,
                            maxWidth: 1600,
                            maxHeight: 1600,
                            imageQuality: 70,
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
                          final photos = await picker.pickMultiImage(
                            maxWidth: 1600,
                            maxHeight: 1600,
                            imageQuality: 70,
                          );
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
              onPressed: selectedPhotos.isEmpty ? null : () => Navigator.pop(context, true),
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

      // Increment this provider's completed-job counter
      try {
        final prov = await supabase
            .from('providers')
            .select('total_jobs')
            .eq('id', providerId!)
            .single();
        final newCount = ((prov['total_jobs'] as int?) ?? 0) + 1;
        await supabase.from('providers').update({'total_jobs': newCount}).eq('id', providerId!);
        if (mounted) setState(() => _totalJobs = newCount);
      } catch (e) {
        debugPrint('total_jobs increment error: $e');
      }

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
        // Persistent dialog (not a SnackBar) so the exact error can be read
        // and screenshotted — a completion failure needs to be diagnosable.
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Could not complete job'),
            content: SingleChildScrollView(child: Text('$e')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
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

  // Shown when the provider has no offer and no active jobs — keeps the screen
  // feeling intentional (and reassuring) instead of blank.
  Widget _buildIdleState() {
    final online = isOnline;
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: (online ? SnowServColors.iceBlue : SnowServColors.inkSoft)
                  .withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              online ? Icons.ac_unit : Icons.nightlight_round,
              size: 34,
              color: online ? SnowServColors.iceBlue : SnowServColors.inkSoft,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            online ? "You're online" : "You're offline",
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: SnowServColors.navy),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              online
                  ? "Waiting for jobs — we'll notify you the moment one comes in."
                  : 'Toggle online above to start receiving job offers.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, height: 1.4, color: SnowServColors.inkSoft),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDispatchCard() {
    final job = _dispatchedJob!;
    final minutes = _secondsRemaining ~/ 60;
    final seconds = _secondsRemaining % 60;
    final timerStr = '$minutes:${seconds.toString().padLeft(2, '0')}';
    final fraction = (_secondsRemaining / _kDispatchSeconds).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [SnowServColors.iceBlue, SnowServColors.navyMid],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: SnowServColors.iceBlue.withOpacity(0.35),
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
            if (job['job_number'] != null)
              Text('Job #${job['job_number']}',
                  style: const TextStyle(color: Colors.white60, fontSize: 11)),
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
                  color: Colors.white.withOpacity(0.15),
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
                      foregroundColor: SnowServColors.iceBlue,
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

  Widget _buildWaitingJobsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.pending_actions, size: 18, color: SnowServColors.iceBlue),
            const SizedBox(width: 6),
            Text('Jobs Waiting (${_waitingJobs.length})',
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: SnowServColors.navy)),
          ],
        ),
        const SizedBox(height: 2),
        Text('Unclaimed jobs you can pick up now — including ones you passed on.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        const SizedBox(height: 8),
        ..._waitingJobs.map((job) => Card(
              color: const Color(0xFFF0F6FF),
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (job['job_number'] != null)
                      Text('Job #${job['job_number']}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    Text(describeJob(job),
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: SnowServColors.navy)),
                    _addressRow(job),
                    const SizedBox(height: 4),
                    Text('Your pay: \$${providerPay(job)}',
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: SnowServColors.iceBlue)),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => claimWaitingJob(job),
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Accept This Job'),
                      ),
                    ),
                  ],
                ),
              ),
            )),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.ac_unit, size: 20, color: SnowServColors.iceBluLight),
            SizedBox(width: 8),
            Text('SnowServ', style: TextStyle(letterSpacing: 0.5)),
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
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: SnowServColors.glacier),
              ),
              child: SwitchListTile(
                title: const Text('Auto-accept jobs while online',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: SnowServColors.navy)),
                subtitle: const Text(
                    'Jobs routed to you are accepted automatically — no offer to catch, nothing to miss.',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                value: _autoAccept,
                activeColor: SnowServColors.iceBlue,
                onChanged: providerId != null ? _toggleAutoAccept : null,
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

                    // Nothing on the plate: show an intentional idle state
                    // instead of blank space.
                    if (_dispatchedJob == null && activeJobs.isEmpty)
                      _buildIdleState(),

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
                                if (job['job_number'] != null)
                                  Text('Job #${job['job_number']}',
                                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
                                // Customer contact — call to sort out a gate, a
                                // dog, where to pile snow, etc.
                                Builder(builder: (_) {
                                  final cust = job['users'];
                                  final name = (cust?['name'] as String?)?.trim();
                                  final phone = (cust?['phone'] as String?)?.trim();
                                  if ((phone == null || phone.isEmpty)) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.person,
                                            size: 15, color: SnowServColors.navy),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                              name?.isNotEmpty == true
                                                  ? name!
                                                  : 'Customer',
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  color: SnowServColors.navy)),
                                        ),
                                        TextButton.icon(
                                          onPressed: () => launchUrl(Uri(
                                              scheme: 'tel',
                                              path: phone.replaceAll(
                                                  RegExp(r'[^0-9+]'), ''))),
                                          icon: const Icon(Icons.call, size: 16),
                                          label: Text(phone),
                                          style: TextButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 8),
                                              minimumSize: const Size(0, 32)),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
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
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _launchNavigation(Map<String, dynamic>.from(job)),
                                    icon: const Icon(Icons.directions, size: 18),
                                    label: const Text('Directions'),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: SnowServColors.iceBlue,
                                      side: const BorderSide(color: SnowServColors.iceBlue),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
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

                    // Jobs waiting board — grabbable unclaimed jobs
                    if (isOnline && _waitingJobs.isNotEmpty)
                      _buildWaitingJobsSection(),

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
                    else if (_dispatchedJob == null &&
                        activeJobs.isEmpty &&
                        _waitingJobs.isEmpty)
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
