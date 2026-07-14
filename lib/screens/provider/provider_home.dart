import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../../config/app_config.dart';
import '../../utils/job_helpers.dart';
import '../../utils/dispatch.dart';
import '../../utils/legal.dart';
import '../../utils/account_deletion.dart';
import 'job_history_screen.dart';
import 'provider_agreement_screen.dart';
import 'provider_details_screen.dart';
import '../faq_screen.dart';
import '../edit_profile_screen.dart';
import '../admin/admin_screen.dart';
import '../../utils/web_layout.dart';

final supabase = Supabase.instance.client;

// How close (meters) the provider's GPS must be to the job's geocoded address to
// count as "on-site". Generous on purpose: geocoding a street address and a phone
// GPS fix each carry ~tens-of-meters error, and a big property/parking spot adds
// more. Past this, the job is flagged "off-site" for the admin — never blocked.
const double _kOnSiteMeters = 300;

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
  int _secondsRemaining = AppConfig.dispatchTimeoutSeconds;
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

    // Pick up any admin change to the dispatch-offer window at the start of each
    // shift, so the provider's countdown length matches the server's expiry.
    if (value) await AppConfig.load();

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
    final window = AppConfig.dispatchTimeoutSeconds;
    _secondsRemaining = (window - elapsed).clamp(0, window);
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

  // Payouts via Stripe Connect Express (#21). We no longer collect or store any
  // bank/SSN details — Stripe does. This checks the provider's Connect status
  // and either opens hosted onboarding (not set up / needs more info) or their
  // Stripe payouts dashboard (already active).
  Future<void> _managePayouts() async {
    if (providerId == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Loading payout setup…')),
    );
    try {
      final res = await supabase.functions.invoke('connect-status');
      final data = (res.data as Map?) ?? const {};
      final onboarded = data['onboarded'] == true;
      final payoutsEnabled = data['payouts_enabled'] == true;

      String? url;
      String note;
      if (onboarded && payoutsEnabled) {
        // Fully set up — open their Stripe Express dashboard to manage it.
        final dash = await supabase.functions
            .invoke('connect-status', body: {'dashboard': true});
        url = ((dash.data as Map?) ?? const {})['dashboard_url'] as String?;
        note = 'Opening your Stripe payouts dashboard…';
      } else {
        // New account, or onboarding not finished — (re)open hosted onboarding.
        final onboard = await supabase.functions.invoke('connect-onboard');
        url = ((onboard.data as Map?) ?? const {})['url'] as String?;
        note = 'Finish payout setup in the browser, then return to SnowServ.';
      }
      if (url == null) throw 'No link returned';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
      final uri = Uri.parse(url);
      if (kIsWeb) {
        await launchUrl(uri, webOnlyWindowName: '_self');
      } else {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open payouts: $e')),
        );
      }
    }
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
                title: const Text('Set up / manage payouts'),
                subtitle: const Text('Bank, ID & 1099 — handled securely by Stripe'),
                onTap: () {
                  Navigator.pop(context);
                  _managePayouts();
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
                  final uid = supabase.auth.currentUser?.id;
                  if (providerId != null) {
                    await supabase.from('providers').update({'is_online': false}).eq('id', providerId!);
                  }
                  // Release this device's push token so pushes for this account
                  // (or the next account that logs in here) don't cross wires.
                  if (uid != null) {
                    try {
                      await supabase.from('profiles').update({'fcm_token': null}).eq('id', uid);
                    } catch (_) {}
                  }
                  await supabase.auth.signOut();
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              // App Store Guideline 5.1.1(v): account deletion must be available
              // in-app. Kept alongside Log Out so it's discoverable, not buried.
              deleteAccountTile(context),
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
    final appleMaps = Uri.parse('https://maps.apple.com/?daddr=$destination');
    final googleMaps = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$destination');
    // Pick the RIGHT app per platform (#8). Apple Maps only makes sense on iOS;
    // on Android an Apple Maps https link opens a blank web page AND launchUrl
    // returns true, so the old "try Apple first, fall back to Google" never fell
    // back. So: Apple on iOS, Google everywhere else, each falling back to the
    // other. kIsWeb guard because Platform isn't available on web.
    final useApple = !kIsWeb && Platform.isIOS;
    final primary = useApple ? appleMaps : googleMaps;
    final fallback = useApple ? googleMaps : appleMaps;
    try {
      final ok = await launchUrl(primary, mode: LaunchMode.externalApplication);
      if (!ok) {
        await launchUrl(fallback, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(fallback, mode: LaunchMode.externalApplication);
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
      // Conditional accept: only claim the job if it's STILL an open offer to
      // this provider. If the offer already expired and re-dispatched, or the
      // customer cancelled in the gap, this updates 0 rows and we bail — so we
      // never notify/capture on a job we didn't actually win.
      final claimed = await supabase
          .from('jobs')
          .update({
            'status': 'assigned',
            'provider_id': providerId,
            'dispatched_to': null,
            if (eta != null) 'eta_minutes': eta,
          })
          .eq('id', jobId)
          .eq('status', 'requested')
          .eq('dispatched_to', providerId!)
          .select('id');
      if (claimed.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('That job is no longer available.')),
          );
        }
        loadActiveJobs();
        return;
      }
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
      // NOTE: we intentionally do NOT auto-open maps on accept. The provider
      // opens navigation on demand via the "Directions" button.
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
      // No auto-navigation on claim either — use the "Directions" button.
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

  // Measures how far the provider's phone currently is from the job's geocoded
  // address, in meters — the raw signal behind on-site verification (#19).
  // Returns null when we simply can't tell: the job was never geocoded, location
  // is denied, or no GPS fix arrives in time. A null NEVER blocks the provider
  // (the required live completion photo is the fallback proof) — it just shows
  // as "location unverified" to the admin.
  Future<double?> _siteDistanceMeters(Map<String, dynamic> job) async {
    final jLat = (job['job_lat'] as num?)?.toDouble();
    final jLng = (job['job_lng'] as num?)?.toDouble();
    if (jLat == null || jLng == null) return null;
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 8));
      return Geolocator.distanceBetween(pos.latitude, pos.longitude, jLat, jLng);
    } catch (e) {
      debugPrint('Site distance error: $e');
      return null;
    }
  }

  // Human-readable distance for the off-site nudge ("about 1.2 km" / "450 m").
  String _formatMeters(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  // Optional "before" photo(s) at Start — a proof-of-work / dispute shield (a
  // snowed-in driveway before the provider clears it). Camera-only (a live shot,
  // like the completion photo) and NOT required: the provider can Skip. Returns
  // the captured files, or null if they backed out of starting the job entirely.
  Future<List<File>?> _captureBeforePhotos() async {
    final List<File> photos = [];
    final picker = ImagePicker();
    bool picking = false; // re-entrancy guard (see completeJob)

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Start Job'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Optional: take a “before” photo',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  const Text(
                      'A quick shot of the snow before you start protects you if the '
                      'customer later disputes the work. You can skip this.',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Take Photo'),
                      onPressed: picking ? null : () async {
                        setDialogState(() => picking = true);
                        try {
                          final photo = await picker.pickImage(
                            source: ImageSource.camera,
                            maxWidth: 1600,
                            maxHeight: 1600,
                            imageQuality: 70,
                          );
                          if (photo != null) photos.add(File(photo.path));
                        } catch (_) {
                          // e.g. already_active from a double-tap — ignore.
                        } finally {
                          setDialogState(() => picking = false);
                        }
                      },
                    ),
                  ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 80,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: photos.length,
                        itemBuilder: (context, i) => Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(photos[i],
                                    width: 80, height: 80, fit: BoxFit.cover),
                              ),
                            ),
                            Positioned(
                              top: 0,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => setDialogState(() => photos.removeAt(i)),
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
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(photos.isEmpty ? 'Skip & Start' : 'Start Job'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return null;
    return photos;
  }

  Future<void> markInProgress(Map<String, dynamic> job) async {
    final jobId = job['id'].toString();
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
      // Offer an optional "before" photo (proof-of-work / dispute shield). The
      // provider can Skip; only Cancel aborts the start. Returns null on Cancel.
      final beforePhotos = await _captureBeforePhotos();
      if (beforePhotos == null) return;
      // Verify the provider is actually at the job (#19). Measured, not enforced:
      // a big distance only prompts a soft "are you sure?" they can override, and
      // the distance is recorded either way for the admin to review.
      final startDist = await _siteDistanceMeters(job);
      if (startDist != null && startDist > _kOnSiteMeters && mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('You seem far from the job'),
            content: Text(
                "Your location is about ${_formatMeters(startDist)} from the service address. "
                "Starting the job captures the customer's payment. Start anyway?"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Not yet'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Start anyway'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }
      // Upload any before photos. Non-fatal on purpose: the before photo is
      // OPTIONAL, so a failed upload must never block Start (which captures the
      // customer's card). On failure we just start without it.
      List<String> beforeUrls = [];
      if (beforePhotos.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Uploading before photo...')),
          );
        }
        try {
          for (final photo in beforePhotos) {
            final fileName =
                'before_${jobId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
            await supabase.storage.from('job-photos').upload(fileName, photo);
            beforeUrls.add(supabase.storage.from('job-photos').getPublicUrl(fileName));
          }
        } catch (e) {
          debugPrint('Before-photo upload failed (non-fatal): $e');
        }
      }
      await supabase.from('jobs').update({
        'status': 'in_progress',
        'start_distance_m': startDist,
        if (beforeUrls.isNotEmpty) 'before_photos': beforeUrls,
      }).eq('id', jobId);
      // The provider has started work — NOW capture the customer's held payment.
      // (Idempotent; a no-op if it was somehow already captured.) This must NOT
      // fail silently (#9): a swallowed failure means the provider works, the
      // job completes, and the customer is never charged with nobody the wiser.
      // It's ADMIN-ONLY, though: the provider isn't shown anything — they can't
      // fix a payment problem and are paid for completed work regardless of
      // whether WE collected from the customer. So on failure we just flag the
      // job; the admin panel surfaces it (red banner + Retry). Non-blocking.
      bool captureOk = false;
      String? captureErr;
      try {
        final res = await supabase.functions.invoke('capture-payment', body: {'job_id': jobId});
        final data = res.data;
        if (data is Map && data['error'] != null) {
          captureErr = data['error'].toString();
        } else {
          captureOk = true;
        }
      } catch (e) {
        captureErr = e.toString();
      }
      if (captureOk) {
        // Clear any stale flag from a prior failed attempt.
        supabase.from('jobs').update({'capture_failed': false, 'capture_error': null}).eq('id', jobId);
      } else {
        debugPrint('Capture failed for $jobId: $captureErr');
        try {
          await supabase.from('jobs').update({
            'capture_failed': true,
            'capture_error': captureErr,
          }).eq('id', jobId);
        } catch (_) {}
        // Intentionally NO provider-facing message — admin-only.
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

  Future<void> completeJob(Map<String, dynamic> job) async {
    final jobId = job['id'].toString();
    final notesController = TextEditingController();
    final List<File> selectedPhotos = [];
    final picker = ImagePicker();
    // Guard against re-entrancy: invoking the picker while one is already open
    // throws PlatformException(already_active) which, left unhandled, corrupts
    // the dialog into a blank box. Track in-flight state to disable both buttons.
    bool picking = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Complete Job'),
          // Bound the width: AlertDialog measures its content's intrinsic width,
          // but a SingleChildScrollView (viewport) can't provide one — that threw
          // "RenderViewport does not support returning intrinsic dimensions" and
          // rendered the whole dialog as a blank white box. maxFinite = use the
          // max available width instead of asking for an intrinsic width.
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('A live photo of the completed work is required:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                const Text('Take at least one photo at the job site to mark this job complete.',
                    style: TextStyle(fontSize: 12, color: Colors.red)),
                const SizedBox(height: 8),
                // Camera only — no gallery. The completion photo has to be taken
                // at the job, on the spot: it's the proof of work (and the
                // fallback when GPS can't verify the provider is on-site, #19).
                // A gallery picker would let any old saved image be uploaded.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.camera_alt),
                    label: const Text('Take Photo'),
                    onPressed: picking ? null : () async {
                      // maxWidth/maxHeight downsize the image at the native
                      // layer, drastically cutting the memory a full-res
                      // camera capture uses. Without this, iOS may kill the
                      // app while the camera is open (blank white screen on
                      // return, lost photo).
                      setDialogState(() => picking = true);
                      try {
                        final photo = await picker.pickImage(
                          source: ImageSource.camera,
                          maxWidth: 1600,
                          maxHeight: 1600,
                          imageQuality: 70,
                        );
                        if (photo != null) selectedPhotos.add(File(photo.path));
                      } catch (_) {
                        // e.g. already_active from a double-tap — ignore.
                      } finally {
                        setDialogState(() => picking = false);
                      }
                    },
                  ),
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

    // Record where the provider was when they marked it done (#19). Verify, not
    // gate: null / far never blocks completion — it just flags the job for the
    // admin. Measured before the upload so a slow upload doesn't skew the fix.
    final completeDist = await _siteDistanceMeters(job);

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
        'complete_distance_m': completeDist,
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

      loadActiveJobs();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Job marked as complete!')),
        );
        // No auto-jump to the next job's map — the provider opens navigation
        // when they choose to, via the "Directions" button on each job.
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

  Widget _buildDispatchCard() {
    final job = _dispatchedJob!;
    final minutes = _secondsRemaining ~/ 60;
    final seconds = _secondsRemaining % 60;
    final timerStr = '$minutes:${seconds.toString().padLeft(2, '0')}';
    final fraction =
        (_secondsRemaining / AppConfig.dispatchTimeoutSeconds).clamp(0.0, 1.0);

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
                                              onPressed: () => completeJob(Map<String, dynamic>.from(job)),
                                              icon: const Icon(Icons.check_circle_outline),
                                              label: const Text('Complete Job'),
                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                                            )
                                          : ElevatedButton.icon(
                                              onPressed: () => markInProgress(Map<String, dynamic>.from(job)),
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
