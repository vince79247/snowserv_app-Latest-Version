import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../theme.dart';
import '../../utils/job_helpers.dart';
import '../../utils/geo.dart';
import '../../config/app_config.dart';
import 'zone_editor_screen.dart';
import 'admin_map_screen.dart';
import 'support_assistant_screen.dart';
import '../../widgets/site_notes_panel.dart';
import '../../utils/auth_actions.dart';

final supabase = Supabase.instance.client;

// Same on-site threshold the provider app uses (#19): within this many meters of
// the job's geocoded address counts as "on-site". Beyond it, the admin card
// flags the job "off-site" so a human can eyeball it before the weekly payout.
const double _kAdminOnSiteMeters = 300;

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
  List<Map<String, dynamic>> disputes = [];
  // Recruiting pipeline — people who might become providers but haven't
  // registered. Fed by the public "work with us" form and by admin cold-outreach.
  List<Map<String, dynamic>> providerLeads = [];
  // Customers whose address fell outside every zone. Written by the order
  // screen and the pre-signup quote; until now nothing READ it, so the
  // demand signal that decides which town to open next was invisible.
  List<Map<String, dynamic>> waitlist = [];
  // Why people deleted their accounts. Anonymous by design — no user id, email
  // or name — so this is a pattern to read, not a person to chase.
  List<Map<String, dynamic>> deletionFeedback = [];
  /// user_ids that have at least one saved service address.
  Set<String> usersWithAddress = {};
  /// Active "book my next storm" standing orders — committed demand for the
  /// next storm, which is the only forward-looking number in the panel.
  List<Map<String, dynamic>> stormBookings = [];
  /// Everything we've emailed anyone, newest first. Bodies are NOT loaded here
  /// (they're the bulk of the table); the history dialog fetches one on demand.
  List<Map<String, dynamic>> emailLog = [];

  int get _pendingDisputes =>
      disputes.where((d) => d['status'] == 'pending').length;
  bool loading = true;
  bool _payoutRunning = false;
  // Cancelled jobs are kept (financial record) but hidden from the main list
  // by default so they don't bury live work; this toggle reveals them.
  bool _showCancelled = false;
  // Admin search filters for the Users / Providers tabs (name, email, phone, #).
  String _customerSearch = '';
  String _providerSearch = '';
  String _jobSearch = '';
  /// null = every status. The Jobs tab is the one that grows without limit —
  /// every storm adds a season's worth — so it needs finding, not just scrolling.
  String? _jobStatusFilter;
  // Fallback poll. Realtime (below) is the fast path; this only catches the case
  // where the socket dropped without us noticing — hence 60s, not 15s.
  Timer? _ticker;
  // Live push from Postgres for the three tables the admin watches during a
  // storm. Vince's complaint that started this: "Why do I have to keep
  // refreshing the app? What if we were live during a snowstorm?"
  RealtimeChannel? _liveChannel;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    loadAll();
    _subscribeLive();
    // Safety net only: a dropped websocket is invisible, so keep a slow poll so
    // the panel can never sit permanently stale. Realtime does the real work.
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _silentRefresh();
    });
  }

  // One channel, three tables. Any insert/update/delete schedules a single
  // coalesced refresh — dispatch alone fires several row writes per job (job +
  // provider), and refetching once per event would hammer the DB and make the
  // list flicker mid-storm.
  void _subscribeLive() {
    final chan = supabase.channel('admin_live');
    for (final table in ['jobs', 'providers', 'disputes']) {
      chan.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (_) => _scheduleRefresh(),
      );
    }
    _liveChannel = chan..subscribe();
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _silentRefresh();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ticker?.cancel();
    if (_liveChannel != null) supabase.removeChannel(_liveChannel!);
    _tabController.dispose();
    super.dispose();
  }

  // Pending-review first, so a new registration lands at the top of the list.
  static List<Map<String, dynamic>> _sortProviders(Iterable<dynamic> rows) {
    final list = List<Map<String, dynamic>>.from(rows);
    list.sort((a, b) {
      const order = {'pending_review': 0, 'approved': 1};
      final aOrder = order[a['registration_status']] ?? 2;
      final bOrder = order[b['registration_status']] ?? 2;
      return aOrder.compareTo(bOrder);
    });
    return list;
  }

  // Quiet background refresh (no spinner) of everything that changes while the
  // admin is just WATCHING — during a storm nobody should have to hit reload:
  //   jobs      → new orders, status changes, the live ticker + "Xm ago"
  //   providers → who's online/offline, and NEW REGISTRATIONS appearing
  //   disputes  → the pending badge
  // Used to re-pull jobs ONLY, so provider online/offline and new provider
  // signups sat frozen until a manual refresh (a registration looked like it had
  // vanished — found 2026-07-29). Queries run in parallel to stay snappy; users /
  // payouts / zones are deliberately left to loadAll (they're not time-critical
  // and users is the heaviest table).
  Future<void> _silentRefresh() async {
    try {
      final results = await Future.wait([
        supabase.from('jobs').select('*, addresses(*)').order('created_at', ascending: false),
        supabase
            .from('providers')
            .select('*, users!inner(name, email, phone)')
            .order('created_at', ascending: false),
        // Resilient like loadAll: a disputes hiccup shouldn't stall the rest.
        supabase
            .from('disputes')
            .select('*, jobs(job_number, final_price, base_price, service_type)')
            .order('created_at', ascending: false)
            .then<dynamic>((v) => v)
            .catchError((_) => disputes),
      ]);
      if (mounted) {
        setState(() {
          jobs = List<Map<String, dynamic>>.from(results[0] as Iterable);
          providers = _sortProviders(results[1] as Iterable);
          disputes = List<Map<String, dynamic>>.from(results[2] as Iterable);
        });
      }
    } catch (_) {
      // Transient network blips shouldn't spam the admin — next tick retries.
    }
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
          .select('*, users!inner(name, email, phone)')
          .order('created_at', ascending: false);
      final payoutsData = await supabase
          .from('jobs')
          .select('*, providers!jobs_provider_id_fkey!inner(provider_number, users!inner(name))')
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
      // Loaded separately (like service_areas) so it's resilient. Customer /
      // provider names are resolved from the already-loaded users/providers lists.
      List<Map<String, dynamic>> disputesList = [];
      try {
        final disputesData = await supabase
            .from('disputes')
            .select('*, jobs(job_number, final_price, base_price, service_type)')
            .order('created_at', ascending: false);
        disputesList = List<Map<String, dynamic>>.from(disputesData);
      } catch (_) {}
      // Recruiting pipeline. Same resilient pattern — this table is new, and a
      // missing/denied read must never take down the rest of the panel.
      List<Map<String, dynamic>> leadsList = [];
      try {
        final leadsData = await supabase
            .from('provider_leads')
            .select()
            .order('created_at', ascending: false);
        leadsList = List<Map<String, dynamic>>.from(leadsData);
      } catch (_) {}

      List<Map<String, dynamic>> waitlistRows = [];
      try {
        final waitData = await supabase
            .from('waitlist')
            .select()
            .order('created_at', ascending: false);
        waitlistRows = List<Map<String, dynamic>>.from(waitData);
      } catch (_) {}

      List<Map<String, dynamic>> churnRows = [];
      try {
        final churnData = await supabase
            .from('account_deletion_feedback')
            .select()
            .order('created_at', ascending: false);
        churnRows = List<Map<String, dynamic>>.from(churnData);
      } catch (_) {}

      // Just the owner ids — who has bothered to save a service address. One
      // column, so it stays cheap even when the table is large. See
      // _looksLikeWrongSide for why an order count alone won't do.
      Set<String> withAddress = {};
      try {
        final addrData = await supabase.from('addresses').select('user_id');
        withAddress = {
          for (final a in List<Map<String, dynamic>>.from(addrData))
            if (a['user_id'] != null) a['user_id'].toString()
        };
      } catch (_) {}

      // Deliberately WITHOUT the body column — it's the bulk of the row and
      // isn't needed to answer "have I written to this person, and when".
      // Reading one message back fetches it on demand.
      List<Map<String, dynamic>> bookingRows = [];
      try {
        final bookingData = await supabase
            .from('storm_bookings')
            .select('*, addresses(address_line, city, zip)')
            .eq('status', 'active')
            .order('created_at', ascending: false);
        bookingRows = List<Map<String, dynamic>>.from(bookingData);
      } catch (_) {}

      List<Map<String, dynamic>> mailRows = [];
      try {
        final mailData = await supabase
            .from('email_log')
            .select('id, to_email, subject, user_id, lead_id, provider_id, '
                'template, created_at')
            .order('created_at', ascending: false)
            .limit(500);
        mailRows = List<Map<String, dynamic>>.from(mailData);
      } catch (_) {}

      if (mounted) {
        final providerList = _sortProviders(providersData);
        setState(() {
          jobs = List<Map<String, dynamic>>.from(jobsData);
          users = List<Map<String, dynamic>>.from(usersData);
          providers = providerList;
          pendingPayouts = List<Map<String, dynamic>>.from(payoutsData);
          serviceAreas = areasList;
          disputes = disputesList;
          providerLeads = leadsList;
          waitlist = waitlistRows;
          deletionFeedback = churnRows;
          usersWithAddress = withAddress;
          emailLog = mailRows;
          stormBookings = bookingRows;
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

  // Admin-editable platform commission. Persists to app_settings via AppConfig
  // so the split updates everywhere (earnings, provider pay, payouts) with no
  // code change.
  Future<void> _editCommission() async {
    final ctrl =
        TextEditingController(text: AppConfig.commissionPct.round().toString());
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Platform commission'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'The % SnowServ keeps from each job. Providers receive the rest. '
                'Applies to new earnings, provider pay, and payouts.',
                style: TextStyle(fontSize: 13, color: SnowServColors.inkSoft)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Commission',
                suffixText: '%',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final pct = double.tryParse(ctrl.text.trim());
    if (pct == null || pct < 0 || pct > 100) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a number between 0 and 100.')));
      }
      return;
    }
    try {
      await AppConfig.setCommissionPct(pct);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Commission set to ${pct.round()}% — providers now keep ${(100 - pct).round()}%.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  // mm:ss for the dispatch window (e.g. 240 -> "4:00").
  String _fmtMMSS(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  // Admin-editable dispatch-offer window. Persists to app_settings via AppConfig;
  // BOTH the provider UI countdown and the pg_cron dispatch_jobs() expiry read
  // the same setting, so they stay in lockstep (no "job no longer available"
  // surprises). Clamped to AppConfig.dispatchTimeout{Min,Max} (60–600s).
  Future<void> _editDispatchTimeout() async {
    final ctrl = TextEditingController(
        text: AppConfig.dispatchTimeoutSeconds.toString());
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dispatch offer window'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'How long a provider has to accept an offered job before it '
                'auto-declines and re-offers to the next driver. Applies to the '
                'provider countdown and the server expiry together.',
                style: TextStyle(fontSize: 13, color: SnowServColors.inkSoft)),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Seconds',
                suffixText: 's',
                helperText: 'Between 60 and 600 (e.g. 240 = 4:00).',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final secs = int.tryParse(ctrl.text.trim());
    if (secs == null ||
        secs < AppConfig.dispatchTimeoutMin ||
        secs > AppConfig.dispatchTimeoutMax) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Enter a number between ${AppConfig.dispatchTimeoutMin} and ${AppConfig.dispatchTimeoutMax} seconds.')));
      }
      return;
    }
    try {
      await AppConfig.setDispatchTimeoutSeconds(secs);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Dispatch window set to ${secs}s (${_fmtMMSS(secs)}).')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  // Admin-editable storm pricing (snow depth -> price multiplier ladder).
  // Persists to app_settings.storm_bands via AppConfig; the
  // create-checkout-session function reads the SAME row, so the customer price
  // scale and the actual charge stay in lockstep. The first band is always the
  // standard price (0"/1.0×) and is fixed — the admin tunes the surge bands'
  // depth thresholds AND their multipliers.
  Future<void> _editStormPricing() async {
    // Editable rows = every band above the 0" standard baseline.
    final rows = AppConfig.stormBands.where((b) => b.minInches > 0).toList();
    final inchCtrls = [
      for (final b in rows) TextEditingController(text: b.minInches.toString())
    ];
    final multCtrls = [
      for (final b in rows) TextEditingController(text: _fmtMult(b.multiplier))
    ];

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Storm pricing'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Price multiplier by snow on the ground. Up to the first '
                'threshold is the standard price (1.0×). Deeper snow uses that '
                'band\'s multiplier. Thresholds must increase down the list.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              const Row(children: [
                Expanded(
                    flex: 5,
                    child: Text('From (inches)',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey))),
                SizedBox(width: 10),
                Expanded(
                    flex: 4,
                    child: Text('Multiplier',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey))),
              ]),
              const SizedBox(height: 4),
              for (int i = 0; i < inchCtrls.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: TextField(
                          controller: inchCtrls[i],
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            suffixText: '"',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 4,
                        child: TextField(
                          controller: multCtrls[i],
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            suffixText: '×',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;

    // Parse + validate (mirrors AppConfig.parseStormBands / the server).
    final mins = <int>[];
    final mults = <double>[];
    for (int i = 0; i < inchCtrls.length; i++) {
      final m = int.tryParse(inchCtrls[i].text.trim());
      final x = double.tryParse(multCtrls[i].text.trim());
      if (m == null || x == null) {
        _stormError('Enter a number in every field.');
        return;
      }
      if (m <= 0) {
        _stormError('Snow-depth thresholds must be greater than 0 inches.');
        return;
      }
      if (x < AppConfig.stormMultMin || x > AppConfig.stormMultMax) {
        _stormError(
            'Multipliers must be between ${AppConfig.stormMultMin.toStringAsFixed(1)}× and ${AppConfig.stormMultMax.toStringAsFixed(1)}×.');
        return;
      }
      if (mins.isNotEmpty && m <= mins.last) {
        _stormError('Each threshold must be deeper than the one above it.');
        return;
      }
      mins.add(m);
      mults.add(x);
    }
    if (mins.isEmpty) {
      _stormError('Keep at least one storm band.');
      return;
    }

    // Rebuild the full ladder with the fixed 0" standard band on top.
    final bands = <StormBand>[
      StormBand(0, mins.first, 1.0),
      for (int i = 0; i < mins.length; i++)
        StormBand(mins[i], i < mins.length - 1 ? mins[i + 1] : null, mults[i]),
    ];
    try {
      await AppConfig.setStormBands(bands);
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Storm pricing updated.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  void _stormError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> toggleUserFlag(String userId, bool currentFlag) async {
    await supabase.from('users').update({'is_flagged': !currentFlag}).eq('id', userId);
    loadAll();
  }

  // Resolve a dispute: 'resolved' (handled) or 'rejected' (no action). Prompts
  // for an optional note that's stored on the dispute for the record.
  Future<void> _resolveDispute(Map<String, dynamic> dispute, String newStatus) async {
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(newStatus == 'resolved' ? 'Mark resolved' : 'Reject dispute'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: noteController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Resolution note (optional)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(newStatus == 'resolved' ? 'Resolve' : 'Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await supabase.from('disputes').update({
        'status': newStatus,
        'resolution': noteController.text.trim().isEmpty ? null : noteController.text.trim(),
        'resolved_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', dispute['id']);

      // Close the loop with whoever reported it — resolving used to update the
      // row and tell nobody, so a customer or provider who complained just got
      // silence. Route by disputes.filed_by (set from the filer's own auth uid),
      // NOT by guessing: pushing a provider's resolution to the customer would
      // leak that a complaint was even made.
      final jobId = dispute['job_id']?.toString();
      var notified = false;
      var emailed = false;
      if (jobId != null) {
        final fn = dispute['filed_by'] == 'provider' ? 'notify-provider' : 'notify-customer';
        try {
          // Best-effort: the dispute IS resolved at this point. A dead FCM token
          // or an offline filer must not look like the resolve failed.
          final res = await supabase.functions.invoke(fn, body: {
            'job_id': jobId,
            'status': newStatus == 'resolved' ? 'dispute_resolved' : 'dispute_closed',
          });
          notified = (res.data is Map) && (res.data['sent'] == 1);
        } catch (_) {}
      }
      // Email as well as push. Push is the instant ping but it's ephemeral —
      // it needs the app installed and notifications on, and it's gone once
      // dismissed. An outcome someone may want to re-read, forward, or argue
      // with needs to exist somewhere durable, and it reaches people who turned
      // push off or deleted the app.
      try {
        final res = await supabase.functions.invoke('send-dispute-email', body: {
          'dispute_id': dispute['id'],
          'kind': newStatus == 'resolved' ? 'resolved' : 'closed',
        });
        emailed = (res.data is Map) && (res.data['sent'] == 1);
      } catch (_) {}
      if (mounted) {
        final verb = newStatus == 'resolved' ? 'resolved' : 'closed';
        // Say which channels actually landed. "Notified" when nothing was
        // delivered is how a silent failure becomes an angry customer.
        final String how;
        if (emailed && notified) {
          how = 'emailed and pushed to the person who reported it.';
        } else if (emailed) {
          how = 'emailed to the person who reported it (no push — notifications off).';
        } else if (notified) {
          how = 'pushed to their phone (email did not send — check Resend).';
        } else {
          how = 'but nothing was delivered — follow up from support@snowserv.app.';
        }
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Dispute $verb — $how'),
          duration: const Duration(seconds: 5),
        ));
      }
      loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    }
  }

  // Compose and send a free-form email AS SnowServ, without leaving the admin
  // panel. Everything else here was a mailto:, which composes from whatever
  // account the admin's mail app defaults to and leaves no record — and which,
  // on the web admin, meant copying an address by hand first.
  //
  // The recipient is passed to the server as an ID, never as an address: the
  // function resolves the email itself so it can't be pointed at a stranger.
  Future<void> _composeEmail(
    Map<String, dynamic> user, {
    String? subject,
    String? body,
  }) async {
    final email = (user['email'] ?? '').toString().trim();
    final userId = user['id']?.toString();
    if (email.isEmpty || userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No email address on file.')));
      return;
    }
    final subjectCtl = TextEditingController(text: subject ?? '');
    final bodyCtl = TextEditingController(text: body ?? '');

    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Email as SnowServ'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('To: $email',
                    style: const TextStyle(
                        fontSize: 12.5, color: SnowServColors.inkSoft)),
                const Text(
                  'Sends from SnowServ, not your own mail account. Replies come '
                  'back to support@snowserv.app.',
                  style: TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: subjectCtl,
                  decoration: const InputDecoration(
                      labelText: 'Subject', isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bodyCtl,
                  minLines: 8,
                  maxLines: 16,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    alignLabelWithHint: true,
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send')),
        ],
      ),
    );

    if (send == true) {
      try {
        final res = await supabase.functions.invoke('send-admin-email', body: {
          'user_id': userId,
          'subject': subjectCtl.text.trim(),
          'body': bodyCtl.text.trim(),
        });
        final sent = (res.data is Map) && (res.data['sent'] == 1);
        if (mounted) {
          final err = (res.data is Map) ? (res.data['error'] ?? '') : '';
          // Mirror the row the server just logged so the "Emailed" chip appears
          // immediately. The snackbar is the receipt; the chip is the memory.
          if (sent) {
            setState(() => emailLog.insert(0, {
                  'to_email': email,
                  'subject': subjectCtl.text.trim(),
                  'user_id': userId,
                  'template': 'admin_freeform',
                  'created_at': DateTime.now().toUtc().toIso8601String(),
                }));
          }
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(sent
                ? 'Sent to $email'
                : 'Could not send${err == '' ? '' : ': $err'}'),
            backgroundColor: sent ? SnowServColors.success : Colors.red,
          ));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not send: $e')));
        }
      }
    }
    subjectCtl.dispose();
    bodyCtl.dispose();
  }

  Map<String, dynamic>? _jobById(String? id) {
    if (id == null) return null;
    for (final j in jobs) {
      if (j['id']?.toString() == id) return j;
    }
    return null;
  }

  /// Is there still money to give back on this job? A cancelled job has already
  /// had its charge refunded or its hold released, so offering to refund it
  /// again is a button that can only ever report "already refunded" — it costs
  /// a confirmation dialog and a round-trip to learn nothing.
  ///
  /// A job we can't find is left refundable: absence of evidence isn't evidence
  /// that the customer was paid back.
  bool _isRefundable(String? jobId) {
    final job = _jobById(jobId);
    return job == null || job['status'] != 'cancelled';
  }

  // Admin-issued refund for [jobId]. refund-job (which already authorizes admins)
  // RELEASES the hold if the charge was never captured, or issues a full Stripe
  // REFUND if it was — then we mark the job cancelled so it drops out of earnings
  // and the weekly provider payout (a refunded job shouldn't pay the provider).
  // Mirrors the customer cancel-refund. Irreversible for a captured charge → confirms.
  Future<void> _refundJob(String? jobId) async {
    if (jobId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Refund this job?'),
        content: const Text(
          'This issues a full refund to the customer (or releases the hold if the '
          'charge was never captured) and marks the job cancelled — so it drops out '
          'of earnings and the provider is NOT paid for it.\n\n'
          "A captured refund posts back to the customer's card in 5–10 business "
          "days and can't be undone.",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Refund'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    String? action;
    bool already = false;
    try {
      final resp =
          await supabase.functions.invoke('refund-job', body: {'job_id': jobId});
      final data = resp.data;
      if (data is Map && data['action'] is String) action = data['action'] as String;
      if (data is Map && data['already'] == true) already = true;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Refund failed: $e'), backgroundColor: Colors.red));
      return;
    }
    // The money movement succeeded → reverse the job (best-effort; if this write
    // fails the refund still stands, so we don't report it as a failure).
    try {
      await supabase.from('jobs').update({'status': 'cancelled'}).eq('id', jobId);
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      // Don't claim we just issued a refund when the money had already gone
      // back — an admin needs to know whether this click moved money or only
      // caught the records up.
      content: Text(already
          ? 'Already refunded — job marked cancelled and the button is now cleared.'
          : action == 'refunded'
              ? "Refund issued — it posts back to the customer's card in 5–10 business days."
              : 'Hold released — the customer was never charged.'),
      backgroundColor: SnowServColors.success,
    ));
    loadAll();
  }

  Widget _buildDisputesTab() {
    if (disputes.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No disputes reported — all quiet. 👍',
              style: TextStyle(color: SnowServColors.inkSoft)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: disputes.length,
      itemBuilder: (context, i) {
        final d = disputes[i];
        final status = (d['status'] ?? 'pending').toString();
        final isPending = status == 'pending';
        final job = d['jobs'] as Map<String, dynamic>?;
        // Resolve names from the already-loaded lists.
        final customer = users.firstWhere(
            (u) => u['id'] == d['customer_id'], orElse: () => const {});
        final provider = providers.firstWhere(
            (p) => p['id'] == d['provider_id'], orElse: () => const {});
        final custName = customer['name'] ?? 'Customer';
        final provName = (provider['users']?['name']) ?? 'Provider';
        final statusColor = isPending
            ? Colors.orange
            : (status == 'resolved' ? SnowServColors.success : SnowServColors.inkSoft);

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(d['reason']?.toString() ?? 'Problem reported',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15, color: SnowServColors.navy)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: statusColor.withOpacity(0.12),
                        border: Border.all(color: statusColor),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(status.toUpperCase(),
                          style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${job?['job_number'] != null ? 'Job #${job!['job_number']} · ' : ''}'
                  '\$${job?['final_price'] ?? job?['base_price'] ?? '—'}',
                  style: const TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
                ),
                // Lead with the side that actually complained — it changes how
                // you read the report and who the resolution push goes to.
                Text(
                  d['filed_by'] == 'provider'
                      ? '$provName (provider) reported this  ·  about $custName (customer)'
                      : d['filed_by'] == 'customer'
                          ? '$custName (customer) reported this  ·  about $provName (provider)'
                          : '$custName (customer)  ·  $provName (provider)',
                  style: const TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
                ),
                if ((d['description'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(d['description'].toString(), style: const TextStyle(fontSize: 13)),
                ],
                if (!isPending && (d['resolution'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Resolution: ${d['resolution']}',
                      style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: SnowServColors.inkSoft)),
                ],
                // Only offer the refund while there is money to give back. The
                // job cards already knew this; the dispute card didn't, so a
                // dispute over an already-refunded job kept a live Refund
                // button that could only ever answer "already refunded".
                // Saying so up front is the answer he wanted.
                if (d['job_id'] != null) ...[
                  const SizedBox(height: 10),
                  if (_isRefundable(d['job_id']?.toString()))
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _refundJob(d['job_id']?.toString()),
                        icon: const Icon(Icons.currency_exchange, size: 16),
                        label: const Text('Refund customer'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red.shade700,
                          side: BorderSide(color: Colors.red.shade300),
                        ),
                      ),
                    )
                  else
                    Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 15, color: Colors.green.shade700),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Already refunded — the customer is not out any money.',
                            style: TextStyle(
                                fontSize: 12, color: Colors.green.shade800),
                          ),
                        ),
                      ],
                    ),
                ],
                if (isPending) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _resolveDispute(d, 'rejected'),
                          child: const Text('Reject'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _resolveDispute(d, 'resolved'),
                          child: const Text('Mark resolved'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> toggleUserSuspend(String userId, bool currentSuspend) async {
    await supabase.from('users').update({'is_suspended': !currentSuspend}).eq('id', userId);
    loadAll();
  }

  // Approving somebody used to tell them NOTHING. They could sit approved for
  // weeks and never know to go online, which throws away the entire recruiting
  // effort that got them here. Both channels on purpose: push reaches them the
  // moment it happens, email survives a missed notification and carries the
  // "connect your bank" instruction that push is too small to hold.
  //
  // Both sends are best-effort — the approval itself has already been written,
  // and a notification failure must never make it look like it did not stick.
  Future<void> approveProvider(String providerId) async {
    await supabase.from('providers').update({
      'is_verified': true,
      'registration_status': 'approved',
    }).eq('id', providerId);

    var emailed = false;
    try {
      final res = await supabase.functions
          .invoke('send-lead-email', body: {'provider_id': providerId});
      emailed = (res.data is Map) && (res.data['sent'] == 1);
    } catch (_) {}
    try {
      await supabase.functions.invoke('notify-provider',
          body: {'provider_id': providerId, 'status': 'approved'});
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(emailed
            ? 'Approved — they have been emailed and notified.'
            : 'Approved. The email did not go out; you can send it from '
                'their card.'),
        backgroundColor: emailed ? SnowServColors.success : Colors.orange,
      ));
    }
    loadAll();
  }

  // Nearly every real "rejection" is administrative and fixable — a blurry ID
  // photo, expired insurance. Those people should be told exactly what to redo
  // and let back in to redo it, which costs one email and gains a provider.
  // Treating them as rejections dead-ends them on a red screen whose only
  // advice was "contact support", manufacturing the support mail it was meant
  // to avoid. So "not approved" is two different actions now, and this list is
  // the fixable one.
  static const _fixableReasons = <String, String>{
    'The photo of your ID came through blurry or cut off. Please retake it in '
        'good light with all four corners visible.': 'ID photo unreadable',
    'The ID you uploaded has expired. Please upload a current one — any '
        'government photo ID works, it does not have to be a driver license.':
        'ID expired',
    'The photo of your insurance card came through blurry or cut off. Please '
        'retake it with the whole card visible.': 'Insurance photo unreadable',
    'Your insurance policy shows as expired. Please upload your current one.':
        'Insurance expired',
    'We could not find insurance on your application. Please add your policy '
        'details and a photo of the card.': 'No insurance on file',
    'The name on your ID does not match the name on your account. Please '
        'update your name so the two match, or upload an ID that matches.':
        'Name does not match ID',
    'You selected a plow truck, but the vehicle details are missing or do not '
        'match the plate. Please fill in the make, model, year and plate.':
        'Truck details missing',
  };

  /// "Needs attention" — the common case. Says what to fix, puts them back in
  /// the registration flow so they can fix it, and tells them both by email and
  /// in the app. NOT a rejection: their work so far is kept.
  Future<void> _requestChanges(Map<String, dynamic> p) async {
    String? chosen;
    final custom = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('What do they need to fix?'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'They get this in an email and at the top of the app, and '
                    'go back into registration to fix it. Their answers are '
                    'kept — they do not start over.',
                    style: TextStyle(fontSize: 12.5, color: SnowServColors.inkSoft),
                  ),
                  const SizedBox(height: 10),
                  for (final e in _fixableReasons.entries)
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: e.key,
                      groupValue: chosen,
                      title: Text(e.value,
                          style: const TextStyle(fontSize: 13)),
                      onChanged: (v) => setLocal(() => chosen = v),
                    ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: custom,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Or write your own (overrides the choice above)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: (chosen == null && custom.text.trim().isEmpty)
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );

    final note = custom.text.trim().isNotEmpty ? custom.text.trim() : chosen;
    custom.dispose();
    if (ok != true || note == null || !mounted) return;

    // Back to 'incomplete' so RoleRouter drops them into the registration flow
    // rather than the dead-end pending screen.
    await supabase.from('providers').update({
      'registration_status': 'incomplete',
      'is_verified': false,
      'review_note': note,
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', p['id']);

    var emailed = false;
    try {
      final res = await supabase.functions.invoke('send-lead-email',
          body: {'provider_id': p['id'], 'review_note': note});
      emailed = (res.data is Map) && (res.data['sent'] == 1);
    } catch (_) {}
    try {
      await supabase.functions.invoke('notify-provider',
          body: {'provider_id': p['id'], 'status': 'needs_attention'});
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(emailed
            ? 'Sent — they can fix it and resubmit.'
            : 'Saved, but the email did not go out. Send it from their card.'),
        backgroundColor: emailed ? SnowServColors.success : Colors.orange,
      ));
    }
    loadAll();
  }

  /// A genuine decline — duplicate account, or something that disqualifies them
  /// outright. Rare. Confirms first because it is the one provider action with
  /// no path back for them.
  Future<void> rejectProvider(String providerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Decline this application?'),
        content: const Text(
          'Use this only when they should not be on the platform at all — a '
          'duplicate account, or something that disqualifies them.\n\n'
          'If the problem is a bad photo, expired insurance, or missing '
          'details, close this and use "Needs attention" instead. That tells '
          'them what to fix and lets them resubmit.\n\n'
          'They will be emailed a short, final note without a specific reason.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await supabase.from('providers').update({
      'is_verified': false,
      'registration_status': 'rejected',
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', providerId);

    try {
      await supabase.functions
          .invoke('send-lead-email', body: {'provider_id': providerId});
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Declined — they have been emailed.')));
    }
    loadAll();
  }

  /// Pull an approved driver off the platform for good. Confirms, because the
  /// realistic reason to do this — lapsed insurance, a document to redo — is
  /// better served by "Needs attention", which explains itself and lets them
  /// come back. Revoke is the last resort.
  Future<void> revokeProvider(String providerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke this driver\'s approval?'),
        content: const Text(
          'They stop receiving jobs immediately and land on a "not approved" '
          'screen with no explanation.\n\n'
          'If the real problem is expired insurance or a document that needs '
          'redoing, close this and use "Needs attention" instead — that tells '
          'them what to fix and lets them come back once they have.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await supabase.from('providers').update({
      'is_verified': false,
      'registration_status': 'rejected',
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', providerId);
    loadAll();
  }

  // Admin "preferred driver" override (providers.preferred_until). While live,
  // this provider wins a new job only when they're EQUAL-OR-CLOSER than the
  // driver who'd otherwise get it (never sent a worse-distance job), and it
  // auto-expires at preferred_until. Implemented in the dispatch_jobs() RPC (see
  // migration 20260707071500_preferred_driver_expiry_distance.sql) — the sole
  // dispatcher now that the client-side one is gone (RLS lockdown Stage 2).

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

  // 1.0 -> "1", 1.5 -> "1.5", 1.25 -> "1.25" (no trailing zeros).
  String _fmtMult(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  // Per-address custom pricing. When a provider flags a property as underpriced
  // (huge driveway, long walkway), set a multiplier here. It stacks on top of
  // storm pricing and applies to FUTURE orders at this saved address.
  Future<void> _setAddressMultiplier(Map<String, dynamic> address) async {
    final id = address['id'];
    if (id == null) return;
    final current = (address['price_multiplier'] as num?)?.toDouble() ?? 1.0;
    final c = TextEditingController(text: _fmtMult(current));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) {
        double sel = current;
        return StatefulBuilder(builder: (ctx, setLocal) {
          void pick(double v) => setLocal(() {
                sel = v;
                c.text = _fmtMult(v);
              });
          return AlertDialog(
            title: const Text('Custom price for this address'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${address['address_line'] ?? ''}, ${address['city'] ?? ''}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: SnowServColors.navy)),
                const SizedBox(height: 12),
                const Text(
                    'Price multiplier — stacks on top of storm pricing and '
                    'applies to future orders at this address. 1× = normal.',
                    style: TextStyle(
                        fontSize: 12, color: SnowServColors.inkSoft)),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final v in [1.0, 1.25, 1.5, 1.75, 2.0])
                      ChoiceChip(
                        label: Text('${_fmtMult(v)}×'),
                        selected: sel == v,
                        onSelected: (_) => pick(v),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: c,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Multiplier', prefixText: '× '),
                  onChanged: (t) =>
                      setLocal(() => sel = double.tryParse(t) ?? sel),
                ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, double.tryParse(c.text) ?? sel),
                child: const Text('Save',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        });
      },
    );
    if (result == null) return;
    final m = result.clamp(0.5, 5.0);
    try {
      await supabase
          .from('addresses')
          .update({'price_multiplier': m}).eq('id', id);
      loadAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(m == 1.0
                ? 'Reset to normal pricing for this address'
                : 'Custom pricing set to ${_fmtMult(m)}× for this address'),
            backgroundColor: SnowServColors.success));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    }
  }

  // Small tappable chip on a job card's address: shows the current custom
  // multiplier (gold) or a "Set price" affordance (blue) → opens the dialog.
  Widget _addrPriceControl(Map<String, dynamic> address) {
    final m = (address['price_multiplier'] as num?)?.toDouble() ?? 1.0;
    final custom = m != 1.0;
    final color = custom ? SnowServColors.warning : SnowServColors.iceBlue;
    return InkWell(
      onTap: () => _setAddressMultiplier(address),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: custom ? 0.12 : 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(custom ? Icons.sell : Icons.sell_outlined,
                size: 12, color: color),
            const SizedBox(width: 3),
            Text(custom ? '${_fmtMult(m)}× price' : 'Set price',
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
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
          IconButton(
            icon: const Icon(Icons.support_agent_outlined),
            tooltip: 'Support Draft Assistant',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SupportAssistantScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Live map',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AdminMapScreen(
                  providers: providers,
                  serviceAreas: serviceAreas,
                  jobs: jobs,
                ),
              ),
            ),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadAll),
          TextButton(
            onPressed: () => signOutSafely(context),
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
                    _buildJobsTab(includeTicker: true),
                    _buildUsersTab(),
                    _buildProvidersTab(),
                    _buildPayoutsTab(),
                    _buildServiceAreasTab(),
                    _buildDisputesTab(),
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

  Map<String, dynamic> _customerRow(dynamic customerId) => users.firstWhere(
      (x) => x['id']?.toString() == customerId?.toString(),
      orElse: () => const {});

  String _customerName(dynamic customerId) {
    final name = (_customerRow(customerId)['name'] as String?)?.trim();
    return (name != null && name.isNotEmpty) ? name : 'Unknown';
  }

  String? _customerPhone(dynamic customerId) =>
      _customerRow(customerId)['phone'] as String?;

  String? _customerEmail(dynamic customerId) =>
      _customerRow(customerId)['email'] as String?;

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

  // Platform-wide earnings from completed jobs, split per the admin-configured
  // commission (AppConfig.commissionPct).
  num get _completedRevenue => jobs
      .where((j) => j['status'] == 'completed')
      .fold<num>(0, (s, j) => s + _jobPrice(j));
  num get _platformEarnings => _completedRevenue * AppConfig.platformFraction;
  num get _providerEarnings => _completedRevenue * AppConfig.providerFraction;

  Future<void> _dial(String scheme, String phone) async {
    final uri = Uri(scheme: scheme, path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));
    if (!await launchUrl(uri) && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$phone')));
    }
  }

  // Opens the admin's mail app (Zoho/Apple Mail/etc.) pre-addressed to the
  // customer — sends from support@snowserv.app if that's the default account.
  // No email backend needed; for branded/templated/logged sends we'd route
  // through the Resend edge function instead (see PRELAUNCH #5).
  Future<void> _email(String address, {String? subject, String? body}) async {
    // Built as a string rather than Uri(query:) because mailto bodies contain
    // newlines and '&', which the query-map form mangles.
    final params = <String>[
      if (subject != null) 'subject=${Uri.encodeComponent(subject)}',
      if (body != null) 'body=${Uri.encodeComponent(body)}',
    ];
    final uri = Uri.parse(
        'mailto:${address.trim()}${params.isEmpty ? '' : '?${params.join('&')}'}');
    if (!await launchUrl(uri) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(address)));
    }
  }

  // Provider take-home for each service, read from the LIVE zone row rather
  // than typed into the template. Recruiting copy quoting stale prices has
  // already cost us once (2026-08-04) — an admin can change zone prices any
  // time, and a number baked into a string here would silently go wrong.
  String _payLines() {
    final zone = serviceAreas.firstWhere(
      (z) => z['is_active'] == true,
      orElse: () => serviceAreas.isEmpty ? <String, dynamic>{} : serviceAreas.first,
    );
    if (zone.isEmpty) return '';
    // Both halves of the split on every line. A bare "$60" under "you keep 75%"
    // reads two ways — is the job $60, or is $60 my share? — and a contractor
    // who guesses low walks away. Plain text, so no table: spell it out.
    String line(String label, dynamic price) {
      final p = num.tryParse('${price ?? ''}');
      if (p == null || p <= 0) return '';
      final cut = (p * AppConfig.providerFraction).round();
      return '  $label: customer pays \$${p.round()}, you take home \$$cut';
    }
    final rows = [
      line('Sidewalk', zone['price_sidewalk']),
      line('Driveway', zone['price_driveway']),
      line('Sidewalk + driveway', zone['price_both']),
    ].where((r) => r.isNotEmpty).toList();
    return rows.isEmpty ? '' : '${rows.join('\n')}\n';
  }

  // Pre-written body for the provider card's Email button. An account stuck at
  // 'incomplete' is a recruiting lead that happens to live in the providers
  // table, and it deserves the same one-tap treatment as the pipeline — a blank
  // draft is the same friction as copy-pasting the address was.
  //
  // Returns null for states where there's nothing useful to say by default;
  // the button then opens an empty draft as before.
  String? _providerEmailBody(Map<String, dynamic> p) {
    final status = p['registration_status']?.toString();
    final first =
        (p['users']?['name'] ?? '').toString().trim().split(RegExp(r'\s+')).first;
    final hi = 'Hi${first.isEmpty ? '' : ' $first'},';
    final pay = _payLines();
    final pct = (AppConfig.providerFraction * 100).round();

    switch (status) {
      case 'incomplete':
        final b = StringBuffer()
          ..writeln(hi)
          ..writeln()
          ..writeln('You created a SnowServ provider account but did not get to '
              'finish setting it up. I wanted to check whether something got in '
              'the way — if any part of it was confusing or did not work, I would '
              'genuinely like to know.')
          ..writeln()
          ..writeln('You do not need to sign up again — your email is already '
              'confirmed. Just log in with the email address and password you '
              'chose and it picks up where you left off.')
          ..writeln()
          ..writeln('There is not much left to do. You add your equipment, sign '
              'the agreement, and connect a bank account for payouts. It takes '
              'about five minutes.')
          ..writeln()
          ..writeln('https://app.snowserv.app')
          ..writeln()
          ..writeln('We are launching in Yonkers this winter. You keep $pct% of '
              'every job — here is what that works out to:')
          ..writeln();
        if (pay.isNotEmpty) b.write(pay);
        b
          ..writeln()
          ..writeln('Deicer pays extra on top of those. No fees, no contract, and '
              'you choose which jobs you take.')
          ..writeln()
          ..writeln('If the bank step is what gave you pause: your details go to '
              'Stripe, not to us. SnowServ never sees or stores your bank account '
              'or Social Security number. Stripe pays you directly and issues '
              'your 1099.')
          ..writeln()
          ..writeln('Just reply if you have any questions.')
          ..writeln()
          ..writeln('Vince')
          ..writeln('SnowServ')
          ..writeln('support@snowserv.app');
        return b.toString();

      case 'pending_review':
        return '$hi\n\n'
            'Thanks for finishing your SnowServ registration — we have it and we '
            'are reviewing it now. You will hear from us as soon as you are '
            'approved, and then you can go online and start taking jobs.\n\n'
            'One thing worth doing in the meantime: connect your bank account for '
            'payouts in the app, so nothing holds up your first payment.\n\n'
            'Reply here with any questions.\n\n'
            'Vince\nSnowServ\nsupport@snowserv.app';

      default:
        return null;
    }
  }

  // One tap from a lead card to a pre-written recruiting email. Vince works
  // leads by email, not phone, so copy-pasting an address off the card was
  // the actual bottleneck in the pipeline.
  // Sends the branded HTML recruiting email server-side (Resend), which is the
  // only way the call to action can be a real BUTTON — a mailto: body is plain
  // text by specification and a bare URL makes the contractor copy and paste.
  Future<void> _sendLeadEmail(Map<String, dynamic> lead) async {
    final address = (lead['email'] ?? '').toString().trim();
    try {
      final res = await supabase.functions
          .invoke('send-lead-email', body: {'lead_id': lead['id']});
      final sent = (res.data is Map) && (res.data['sent'] == 1);
      if (!mounted) return;
      if (sent) {
        // The function advances the row itself; mirror it so the chip updates
        // without a full reload.
        setState(() {
          if ((lead['status'] ?? 'new') == 'new') lead['status'] = 'contacted';
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Sent to $address')));
      } else {
        final err = (res.data is Map) ? (res.data['error'] ?? '') : '';
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not send${err == '' ? '' : ': $err'}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send: $e')));
      }
    }
  }

  Future<void> _emailLead(Map<String, dynamic> lead) async {
    final address = (lead['email'] ?? '').toString().trim();
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This lead has no email address.')));
      return;
    }
    // One tap lands on the send confirmation — that's the thing you came here
    // to do. "Write my own" is one button away for when a reply needs a human
    // touch, and it's labelled so the tracking trade-off is visible.
    final contacted = (lead['status'] ?? 'new') != 'new';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(contacted ? 'Email them again?' : 'Email this lead?'),
        content: Text(contacted
            ? 'You have already contacted $address. Sending again gives them the '
                'current pay rates and a link to create their account.'
            : 'Sends from SnowServ to $address — current pay rates and a button '
                'to create their account.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'draft'), child: const Text('Write my own')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 'send'), child: const Text('Send')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'send') return _sendLeadEmail(lead);
    final first = (lead['name'] ?? '').toString().trim().split(RegExp(r'\s+')).first;
    final pay = _payLines();
    final body = StringBuffer()
      ..writeln('Hi${first.isEmpty ? '' : ' $first'},')
      ..writeln()
      ..writeln('Thanks for signing up to clear snow with SnowServ.')
      ..writeln()
      ..writeln('We are a snow removal app launching in Yonkers this winter. '
          'Customers order a driveway or sidewalk from their phone and the job '
          'goes to the nearest available provider. You pick which jobs you take '
          'and you keep your own schedule.')
      ..writeln()
      ..writeln('You keep '
          '${(AppConfig.providerFraction * 100).round()}% of every job:')
      ..writeln();
    if (pay.isNotEmpty) body.write(pay);
    body
      ..writeln()
      ..writeln('Deicer pays extra on top of those.')
      ..writeln()
      ..writeln('There are no sign-up fees, no monthly fees and no contract.')
      ..writeln()
      ..writeln('Your bank details go to Stripe, not to us. You set up payouts '
          'on Stripe\'s own secure page — SnowServ never sees or stores your '
          'bank account or Social Security number. Stripe pays you directly and '
          'issues your 1099 at the end of the year.')
      ..writeln()
      ..writeln('To get started, create your provider account here:')
      ..writeln('https://app.snowserv.app')
      ..writeln()
      ..writeln('Reply to this email if you have any questions and I will get '
          'right back to you.')
      ..writeln()
      ..writeln('Vince')
      ..writeln('SnowServ')
      ..writeln('support@snowserv.app');

    await _email(address,
        subject: 'Clearing snow with SnowServ this winter', body: body.toString());

    if (!mounted) return;
    if ((lead['status'] ?? 'new') == 'new') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Draft opened in your mail app.'),
        action: SnackBarAction(
          label: 'Mark contacted',
          onPressed: () => _setLeadStatus(lead, 'contacted'),
        ),
      ));
    }
  }

  // Phone + Call/Text quick actions. The simplest "message a driver/customer"
  // path — opens the phone's native dialer / Messages, no chat backend needed.
  Widget _contactRow(String label, String? phone) {
    final has = phone != null && phone.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.phone, size: 16, color: SnowServColors.navy),
          const SizedBox(width: 8),
          Expanded(
            child: Text(has ? '$label: $phone' : '$label: none on file',
                style: TextStyle(
                    fontSize: 13,
                    color: has ? SnowServColors.navy : Colors.grey)),
          ),
          if (has) ...[
            TextButton.icon(
              onPressed: () => _dial('tel', phone),
              icon: const Icon(Icons.call, size: 16),
              label: const Text('Call'),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32)),
            ),
            TextButton.icon(
              onPressed: () => _dial('sms', phone),
              icon: const Icon(Icons.sms, size: 16),
              label: const Text('Text'),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32)),
            ),
          ],
        ],
      ),
    );
  }

  // Email quick action — its own row because addresses are long. Opens the
  // admin's mail client pre-addressed (optionally with a subject).
  /// [onSend] replaces the default mailto: draft. Prefer it wherever a written
  /// template exists: a mailto composes from whatever account the admin's mail
  /// app defaults to, which put Vince's personal Yahoo address in the From line
  /// of a provider email. A server send is always from SnowServ.
  Widget _emailRow(String label, String? email,
      {String? subject, String? body, VoidCallback? onSend}) {
    if (email == null || email.trim().isEmpty) return const SizedBox.shrink();
    final mail = _mailFor(email: email);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.email_outlined, size: 16, color: SnowServColors.navy),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(email,
                    maxLines: 1,
                    style: const TextStyle(
                        fontSize: 13, color: SnowServColors.navy)),
                if (mail.isNotEmpty)
                  InkWell(
                    onTap: () => _showMailHistory(email, mail),
                    child: Text(
                      mail.length == 1
                          ? 'Emailed ${_shortDate(mail.first['created_at'])}'
                          : '${mail.length} emails · last '
                              '${_shortDate(mail.first['created_at'])}',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.green.shade800),
                    ),
                  ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed:
                onSend ?? () => _email(email, subject: subject, body: body),
            icon: const Icon(Icons.send_outlined, size: 16),
            label: const Text('Email'),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32)),
          ),
        ],
      ),
    );
  }

  // Completed jobs clustered into "storms": runs of consecutive active days
  // (a gap of >1 day starts a new storm), newest first. A snow business earns in
  // bursts, so this reads far clearer than one all-time lump sum.
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String _dateRange(DateTime a, DateTime b) {
    if (a == b) return '${_months[a.month - 1]} ${a.day}, ${a.year}';
    if (a.year == b.year && a.month == b.month) {
      return '${_months[a.month - 1]} ${a.day}–${b.day}, ${a.year}';
    }
    return '${_months[a.month - 1]} ${a.day} – ${_months[b.month - 1]} ${b.day}, ${b.year}';
  }

  List<Map<String, dynamic>> _stormBuckets() {
    final byDay = <DateTime, List<num>>{}; // day -> [count, revenue]
    for (final j in jobs.where((j) => j['status'] == 'completed')) {
      final created = DateTime.tryParse('${j['created_at']}')?.toLocal();
      if (created == null) continue;
      final day = DateTime(created.year, created.month, created.day);
      final e = byDay.putIfAbsent(day, () => <num>[0, 0]);
      e[0] += 1;
      e[1] += _jobPrice(j);
    }
    if (byDay.isEmpty) return [];
    final days = byDay.keys.toList()..sort();
    final storms = <Map<String, dynamic>>[];
    DateTime? start, end;
    int cnt = 0;
    num rev = 0;
    void flush() {
      final s = start, e = end;
      if (s == null || e == null) return;
      storms.add({
        'label': _dateRange(s, e),
        'jobs': cnt,
        'revenue': rev,
        'end': e,
      });
    }

    for (final d in days) {
      if (start == null) {
        start = d;
        end = d;
        cnt = byDay[d]![0].toInt();
        rev = byDay[d]![1];
      } else if (d.difference(end!).inDays <= 1) {
        end = d;
        cnt += byDay[d]![0].toInt();
        rev += byDay[d]![1];
      } else {
        flush();
        start = d;
        end = d;
        cnt = byDay[d]![0].toInt();
        rev = byDay[d]![1];
      }
    }
    flush();
    storms.sort((a, b) => (b['end'] as DateTime).compareTo(a['end'] as DateTime));
    return storms;
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
              const Text('Earnings'),
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
        Tab(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Disputes'),
              if (_pendingDisputes > 0) ...[
                const SizedBox(width: 6),
                CircleAvatar(
                  radius: 8,
                  backgroundColor: Colors.red,
                  child: Text('$_pendingDisputes',
                      style: const TextStyle(fontSize: 10, color: Colors.white)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // Wide-screen dashboard: columns of fixed-height panels, each reusing a tab
  // builder. Panels scroll internally; the page scrolls if the columns run past
  // the viewport. Everything visible without a single tab click.
  //   >= 1100px  → THREE columns, with Earnings & Payouts in the middle.
  //   900–1100px → two columns (earnings stacked in the left column).
  Widget _buildDashboard() {
    final threeCol = MediaQuery.of(context).size.width >= 1100;

    final jobsPanel = _dashPanel(
        'Jobs (${jobs.length})', Icons.work_outline, _buildJobsTab(), 640);
    final zonesPanel = _dashPanel('Zones (${serviceAreas.length})',
        Icons.map_outlined, _buildServiceAreasTab(), 460);
    final earningsPanel = _dashPanel(
        pendingPayouts.isEmpty
            ? 'Earnings & Payouts'
            : 'Earnings & Payouts (${pendingPayouts.length} due)',
        Icons.payments_outlined,
        _buildPayoutsTab(),
        threeCol ? 820 : 480);
    final providersPanel = _dashPanel('Providers (${providers.length})',
        Icons.local_shipping_outlined, _buildProvidersTab(), 640);
    final customersPanel = _dashPanel('Customers ($_customerCount)',
        Icons.people_outline, _buildUsersTab(), 560);
    final disputesPanel = _dashPanel(
        _pendingDisputes > 0 ? 'Disputes ($_pendingDisputes)' : 'Disputes',
        Icons.flag_outlined, _buildDisputesTab(), 460);

    Widget col(List<Widget> panels) =>
        Expanded(child: Column(children: panels));

    return SingleChildScrollView(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Live ops ticker spans the full width, above the columns.
          _buildLiveTicker(),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: threeCol
                ? [
                    // Left: operations.
                    col([jobsPanel, zonesPanel]),
                    // Middle: the money view, front and centre.
                    col([earningsPanel, disputesPanel]),
                    // Right: people.
                    col([providersPanel, customersPanel]),
                  ]
                : [
                    col([jobsPanel, earningsPanel, zonesPanel]),
                    col([providersPanel, customersPanel, disputesPanel]),
                  ],
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
                              'Sidewalk \$${a['price_sidewalk']}  •  Driveway \$${a['price_driveway']}  •  Both \$${a['price_both']}\n'
                              'Deicer +\$${a['price_salting_sidewalk'] ?? a['price_salting']} / '
                              '+\$${a['price_salting_driveway'] ?? a['price_salting']} / '
                              '+\$${a['price_salting']} (sidewalk / driveway / both)',
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

  // Driver display name for a job's provider_id, resolved from the loaded
  // providers list (avoids an extra join on the jobs query).
  String _providerName(dynamic providerId) {
    if (providerId == null) return 'Unassigned';
    final p = providers.firstWhere(
        (p) => p['id']?.toString() == providerId.toString(),
        orElse: () => <String, dynamic>{});
    final n = p['users']?['name'];
    final base =
        (n == null || n.toString().trim().isEmpty) ? 'Driver' : n.toString();
    final num = p['provider_number'];
    return num == null ? base : '$base #$num';
  }

  String? _providerPhone(dynamic providerId) {
    if (providerId == null) return null;
    final p = providers.firstWhere(
        (p) => p['id']?.toString() == providerId.toString(),
        orElse: () => <String, dynamic>{});
    final ph = p['users']?['phone'];
    return (ph == null || ph.toString().trim().isEmpty) ? null : ph.toString();
  }

  // Manual dispatch override: an "Assign / Reassign driver" button on requested &
  // assigned job cards. Auto-dispatch (dispatch.dart / dispatch_jobs) handles the
  // normal case; this is the admin's on-demand control for edge cases — coverage
  // gaps, a driver who won't take a far job, or hand-placing a specific driver.
  // Only shown pre-start: payment is still a HOLD until the provider STARTS, so
  // switching drivers here moves no money (capture keys off whoever starts).
  Widget _assignControl(Map<String, dynamic> job) {
    final assigned = job['provider_id'] != null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: () => _showAssignDialog(job),
          icon: Icon(assigned ? Icons.swap_horiz : Icons.person_add_alt_1,
              size: 16),
          style: OutlinedButton.styleFrom(
            foregroundColor: SnowServColors.navy,
            side: BorderSide(color: SnowServColors.navy.withOpacity(0.4)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          label: Text(assigned ? 'Reassign driver' : 'Assign driver',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Future<void> _showAssignDialog(Map<String, dynamic> job) async {
    // Eligible = approved drivers. A manual override can pick anyone approved,
    // even offline (admin may be coordinating by phone) — online is shown first,
    // then least-busy, with each driver's live active-job count for judgment.
    final approved = providers
        .where((p) => p['registration_status'] == 'approved')
        .toList();

    final Map<String, int> load = {};
    for (final j in jobs) {
      if (j['status'] == 'assigned' || j['status'] == 'in_progress') {
        final pid = j['provider_id']?.toString();
        if (pid != null) load[pid] = (load[pid] ?? 0) + 1;
      }
    }
    approved.sort((a, b) {
      final ao = a['is_online'] == true ? 0 : 1;
      final bo = b['is_online'] == true ? 0 : 1;
      if (ao != bo) return ao.compareTo(bo);
      return (load[a['id']?.toString()] ?? 0)
          .compareTo(load[b['id']?.toString()] ?? 0);
    });

    final currentId = job['provider_id']?.toString();

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(currentId == null ? 'Assign driver' : 'Reassign driver',
            style: const TextStyle(
                color: SnowServColors.navy, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 380,
          child: approved.isEmpty
              ? const Text('No approved drivers yet.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: approved.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final p = approved[i];
                    final id = p['id']?.toString();
                    final online = p['is_online'] == true;
                    final n = load[id] ?? 0;
                    final isCurrent = id == currentId;
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.circle,
                          size: 10,
                          color: online ? Colors.green : Colors.grey),
                      title: Text(_providerName(id),
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(
                          '${online ? 'Online' : 'Offline'} · $n active${isCurrent ? ' · current' : ''}',
                          style: const TextStyle(fontSize: 12)),
                      trailing: isCurrent
                          ? const Text('current',
                              style:
                                  TextStyle(fontSize: 11, color: Colors.grey))
                          : const Icon(Icons.chevron_right, size: 18),
                      enabled: !isCurrent,
                      onTap: isCurrent ? null : () => Navigator.pop(ctx, p),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
        ],
      ),
    );
    if (chosen != null) await _assignJobToProvider(job, chosen);
  }

  Future<void> _assignJobToProvider(
      Map<String, dynamic> job, Map<String, dynamic> provider) async {
    final providerId = provider['id'];
    try {
      // Place the job straight into 'assigned' under the chosen driver and clear
      // any pending auto-dispatch offer. The BEFORE UPDATE trigger stamps
      // accepted_at when status crosses into 'assigned' (server clock).
      await supabase.from('jobs').update({
        'provider_id': providerId,
        'status': 'assigned',
        'dispatched_to': null,
        'dispatched_at': null,
      }).eq('id', job['id']);

      // Tell the driver a job landed on them (fire-and-forget — a failed push
      // must not undo the assignment).
      try {
        await supabase.functions.invoke('notify-provider',
            body: {'job_id': job['id'], 'status': 'admin_assigned'});
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Assigned to ${_providerName(providerId)}'),
          backgroundColor: SnowServColors.navy,
        ));
      }
      await loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Assign failed: $e'),
            backgroundColor: Colors.red));
      }
    }
  }

  // Compact "N min ago" from an ISO timestamp.
  String _ago(dynamic ts) {
    final t = DateTime.tryParse(ts?.toString() ?? '')?.toLocal();
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  // LIVE ticker: jobs currently being worked (in_progress) or accepted and
  // en route (assigned). Refreshed silently every 30s by _silentRefresh.
  Widget _buildLiveTicker() {
    final active = jobs
        .where((j) =>
            j['status'] == 'in_progress' || j['status'] == 'assigned')
        .toList()
      ..sort((a, b) {
        int rank(Map j) => j['status'] == 'in_progress' ? 0 : 1;
        final r = rank(a).compareTo(rank(b));
        if (r != 0) return r;
        return (b['created_at'] ?? '')
            .toString()
            .compareTo((a['created_at'] ?? '').toString());
      });

    final inProgress = active.where((j) => j['status'] == 'in_progress').length;

    return Container(
      margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      decoration: BoxDecoration(
        color: SnowServColors.navy,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _PulseDot(),
              const SizedBox(width: 8),
              const Text('LIVE',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1.2)),
              const SizedBox(width: 8),
              Text(
                active.isEmpty
                    ? 'No active jobs right now'
                    : '$inProgress in progress · ${active.length} active',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          if (active.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: active.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _tickerCard(active[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tickerCard(Map<String, dynamic> job) {
    final started = job['status'] == 'in_progress';
    final accent = started ? Colors.green : Colors.orange;
    return Container(
      width: 210,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(started ? 'IN PROGRESS' : 'EN ROUTE',
                    style: TextStyle(
                        color: accent.shade800,
                        fontSize: 10,
                        fontWeight: FontWeight.bold)),
              ),
              const Spacer(),
              if (job['job_number'] != null)
                Text('#${job['job_number']}',
                    style:
                        const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
          Text(describeJob(job),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: SnowServColors.navy)),
          Row(children: [
            const Icon(Icons.person, size: 12, color: Colors.grey),
            const SizedBox(width: 3),
            Expanded(
              child: Text(_customerName(job['customer_id']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12)),
            ),
          ]),
          Row(children: [
            const Icon(Icons.local_shipping, size: 12, color: Colors.grey),
            const SizedBox(width: 3),
            Expanded(
              child: Text(_providerName(job['provider_id']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            Text(_ago(job['created_at']),
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ]),
        ],
      ),
    );
  }

  // Provider lifecycle timeline (accepted / started / finished), recorded by the
  // DB trigger on each status transition. Hidden until the job is accepted.
  Widget _jobTimeline(Map<String, dynamic> job) {
    final accepted = job['accepted_at'];
    final started = job['started_at'];
    final finished = job['completed_at'];
    if (accepted == null && started == null && finished == null) {
      return const SizedBox.shrink();
    }
    final onSite = durationBetween(started, finished);
    Widget row(IconData icon, Color color, String label, dynamic ts,
        {String? trailing}) {
      return Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            SizedBox(
              width: 60,
              child: Text(label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
            Text(formatDateTime(ts),
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: SnowServColors.navy)),
            if (trailing != null && trailing.isNotEmpty)
              Text('   $trailing',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.green.shade700)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: SnowServColors.frost,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SnowServColors.glacier),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('JOB TIMELINE',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  letterSpacing: 0.5)),
          const SizedBox(height: 2),
          row(Icons.check_circle_outline, Colors.blue, 'Accepted', accepted),
          row(Icons.play_arrow_rounded, Colors.green, 'Started', started),
          row(Icons.flag_rounded, Colors.grey, 'Finished', finished,
              trailing: onSite.isEmpty ? null : '$onSite on site'),
        ],
      ),
    );
  }

  /// Free-text match over the things you'd actually have in front of you when
  /// looking a job up: a job number off a receipt, a name from an email, or a
  /// street from a complaint.
  bool _matchesJob(Map<String, dynamic> j, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final addr = j['addresses'] as Map<String, dynamic>?;
    final hay = [
      j['job_number'],
      _customerName(j['customer_id']),
      _providerName(j['provider_id']),
      addr?['address_line'],
      addr?['city'],
      addr?['zip'],
      j['service_type'],
      j['status'],
    ].map((v) => (v ?? '').toString()).join(' ').toLowerCase();
    // "#412" and "412" should both find job 412.
    return hay.contains(q.startsWith('#') ? q.substring(1) : q);
  }

  static const _jobStatusLabels = {
    'requested': 'Waiting',
    'assigned': 'Assigned',
    'in_progress': 'In progress',
    'completed': 'Completed',
    'cancelled': 'Cancelled',
  };

  Widget _buildJobsTab({bool includeTicker = false}) {
    final cancelledCount =
        jobs.where((j) => j['status'] == 'cancelled').length;

    // A chosen status wins outright — picking "Cancelled" and then being shown
    // nothing because the show-cancelled switch is off would be nonsense.
    final byStatus = _jobStatusFilter != null
        ? jobs.where((j) => j['status'] == _jobStatusFilter).toList()
        : (_showCancelled
            ? jobs
            : jobs.where((j) => j['status'] != 'cancelled').toList());
    final visible = byStatus.where((j) => _matchesJob(j, _jobSearch)).toList();
    final filtering = _jobSearch.trim().isNotEmpty || _jobStatusFilter != null;

    return Column(
      children: [
        if (includeTicker) _buildLiveTicker(),
        _dispatchTimerBar(),
        _stormPricingBar(),
        _searchField('Search jobs by #, name, address, or ZIP',
            (v) => setState(() => _jobSearch = v)),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            children: [
              ChoiceChip(
                label: Text('All (${jobs.length})'),
                selected: _jobStatusFilter == null,
                onSelected: (_) => setState(() => _jobStatusFilter = null),
              ),
              for (final e in _jobStatusLabels.entries)
                if (jobs.any((j) => j['status'] == e.key))
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: Text('${e.value} '
                          '(${jobs.where((j) => j['status'] == e.key).length})'),
                      selected: _jobStatusFilter == e.key,
                      onSelected: (v) => setState(
                          () => _jobStatusFilter = v ? e.key : null),
                    ),
                  ),
              // Only meaningful while no status is chosen; a status filter
              // already decides whether cancelled jobs are in scope.
              if (cancelledCount > 0 && _jobStatusFilter == null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: FilterChip(
                    label: Text('Show cancelled ($cancelledCount)'),
                    selected: _showCancelled,
                    onSelected: (v) => setState(() => _showCancelled = v),
                    avatar: Icon(
                      _showCancelled ? Icons.visibility : Icons.visibility_off,
                      size: 16,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      jobs.isEmpty
                          ? 'No jobs yet.'
                          : filtering
                              ? 'No jobs match that.'
                              : 'No active jobs — cancelled ones are hidden.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              : _jobsListView(visible),
        ),
      ],
    );
  }

  // Compact settings row at the top of the Jobs tab: shows the current dispatch
  // offer window and lets the admin tune it (single source of truth via
  // AppConfig — both the provider countdown and the cron expiry follow it).
  // Compact summary of the storm ladder in the Jobs tab, e.g.
  // "3"→1.3× · 6"→1.7× · 10"→2.3×". Tap to edit the thresholds + multipliers.
  Widget _stormPricingBar() {
    final surge = AppConfig.stormBands.where((b) => b.minInches > 0).toList();
    final summary = surge.isEmpty
        ? 'standard price only'
        : surge
            .map((b) => '${b.minInches}"→${_fmtMult(b.multiplier)}×')
            .join('  ·  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        onTap: _editStormPricing,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.orange.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.ac_unit, size: 16, color: Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Storm pricing: $summary',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange),
                ),
              ),
              const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.tune, size: 14, color: Colors.orange),
                SizedBox(width: 4),
                Text('Edit',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.orange)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dispatchTimerBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        onTap: _editDispatchTimeout,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: SnowServColors.iceBlue.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.timer_outlined, size: 16, color: SnowServColors.navy),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Dispatch offer window: ${_fmtMMSS(AppConfig.dispatchTimeoutSeconds)}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: SnowServColors.navy),
                ),
              ),
              const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.tune, size: 14, color: SnowServColors.iceBlue),
                SizedBox(width: 4),
                Text('Edit',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: SnowServColors.iceBlue)),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _jobsListView(List<Map<String, dynamic>> list) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final job = list[i];
        final hasNotes = job['provider_notes'] != null &&
            job['provider_notes'].toString().isNotEmpty;
        final photos = (job['completion_photos'] as List<dynamic>? ?? []);
        final beforePhotos = (job['before_photos'] as List<dynamic>? ?? []);
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
                    Builder(builder: (_) {
                      final status = job['status'];
                      final amt = _jobPrice(job);
                      final cancelled = status == 'cancelled';
                      // Payment reflects the hold model: charged only once the
                      // provider STARTS (in_progress/completed); requested/
                      // assigned is a hold; cancelled = refunded/released.
                      final charged =
                          status == 'in_progress' || status == 'completed';
                      final String payLabel;
                      final Color payColor;
                      if (cancelled) {
                        payLabel = 'Refunded / hold released — not charged';
                        payColor = Colors.grey;
                      } else if (charged) {
                        payLabel = 'Customer paid: \$${amt.round()}';
                        payColor = Colors.green;
                      } else {
                        payLabel =
                            'Hold placed (not charged yet): \$${amt.round()}';
                        payColor = Colors.orange.shade800;
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(payLabel,
                              style: TextStyle(
                                  color: payColor,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                          // The split only means anything once money is captured.
                          if (!cancelled)
                            Text(
                              'Provider pay: \$${(amt * AppConfig.providerFraction).round()}  |  Commission: \$${(amt * AppConfig.platformFraction).round()}',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                        ],
                      );
                    }),
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
                // Admin refund — charged jobs only (a hold is released, a captured
                // charge is refunded); cancelled jobs are already reversed.
                if (job['status'] == 'in_progress' || job['status'] == 'completed')
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _refundJob(job['id']?.toString()),
                      icon: Icon(Icons.currency_exchange,
                          size: 15, color: Colors.red.shade700),
                      label: Text('Refund customer',
                          style:
                              TextStyle(fontSize: 12, color: Colors.red.shade700)),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
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
                _contactRow('Customer', _customerPhone(job['customer_id'])),
                _emailRow('Customer', _customerEmail(job['customer_id']),
                    subject: job['job_number'] != null
                        ? 'SnowServ — regarding your order #${job['job_number']}'
                        : 'SnowServ — regarding your order'),
                Row(
                  children: [
                    const Icon(Icons.local_shipping,
                        size: 13, color: Colors.blueGrey),
                    const SizedBox(width: 4),
                    Text('Provider: ${_providerName(job['provider_id'])}',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: job['provider_id'] == null
                                ? Colors.grey
                                : SnowServColors.navy)),
                  ],
                ),
                _contactRow('Provider', _providerPhone(job['provider_id'])),
                if (job['addresses'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${job['addresses']['address_line']}, ${job['addresses']['city']}',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _addrPriceControl(
                            Map<String, dynamic>.from(job['addresses'])),
                      ],
                    ),
                  ),
                Text(formatDate(job['created_at']),
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                // Standing notes on this PROPERTY (survive the job). Admin can
                // hard-delete anything a provider shouldn't have written.
                if (job['address_id'] != null)
                  SiteNotesPanel(
                    key: ValueKey('adminnotes-${job['address_id']}'),
                    addressId: '${job['address_id']}',
                    canAdd: false,
                    isAdmin: true,
                    dense: true,
                  ),
                _jobTimeline(job),
                _locationVerification(job),
                _captureFailedBanner(job),
                if (job['status'] == 'requested' ||
                    job['status'] == 'assigned')
                  _assignControl(job),
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
                if (beforePhotos.isNotEmpty)
                  _labeledPhotoGrid('Before (at start)', beforePhotos),
                if (photos.isNotEmpty)
                  _labeledPhotoGrid('After (completion)', photos),
              ],
            ),
          ),
        );
      },
    );
  }

  // On-site verification for the provider's Start/Complete taps (#19). One chip
  // per phase: green on-site, amber off-site (with the distance), grey when the
  // location couldn't be measured (denied / no fix / never geocoded). Only shown
  // once work has begun — meaningless for a requested/assigned job.
  Widget _locationVerification(Map<String, dynamic> job) {
    final status = job['status'];
    final started = status == 'in_progress' || status == 'completed';
    if (!started) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _locChip('Start', job['start_distance_m']),
          if (status == 'completed') _locChip('Complete', job['complete_distance_m']),
        ],
      ),
    );
  }

  Widget _locChip(String label, dynamic distRaw) {
    final double? d = (distRaw as num?)?.toDouble();
    final Color color;
    final IconData icon;
    final String text;
    if (d == null) {
      color = Colors.grey;
      icon = Icons.location_off;
      text = '$label · location unverified';
    } else if (d <= _kAdminOnSiteMeters) {
      color = Colors.green.shade700;
      icon = Icons.check_circle;
      text = '$label · on-site';
    } else {
      color = Colors.orange.shade800;
      icon = Icons.wrong_location;
      final dist =
          d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km' : '${d.round()} m';
      text = '$label · off-site ($dist away)';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // A labeled 3-across photo grid — used for the before/after pair on a job card.
  Widget _labeledPhotoGrid(String label, List<dynamic> urls) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
          const SizedBox(height: 6),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 6,
              mainAxisSpacing: 6,
            ),
            itemCount: urls.length,
            itemBuilder: (_, i) => ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                urls[i].toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Retry a payment capture that failed when the provider started the job (#9).
  Future<void> _retryCapture(Map<String, dynamic> job) async {
    try {
      final res = await supabase.functions
          .invoke('capture-payment', body: {'job_id': job['id']});
      final data = res.data;
      if (data is Map && data['error'] != null) throw data['error'].toString();
      await supabase
          .from('jobs')
          .update({'capture_failed': false, 'capture_error': null}).eq('id', job['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Payment captured.')));
      }
      loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Retry failed: $e')));
      }
    }
  }

  // Loud banner on a job whose payment capture failed at Start (#9) — the
  // customer may be uncharged, so it needs a human to retry or investigate.
  Widget _captureFailedBanner(Map<String, dynamic> job) {
    if (job['capture_failed'] != true) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        border: Border.all(color: Colors.red),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.error_outline, size: 16, color: Colors.red),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Payment not captured',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.red, fontSize: 13)),
            ),
            OutlinedButton.icon(
              onPressed: () => _retryCapture(job),
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
            ),
          ]),
          if (job['capture_error'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(job['capture_error'].toString(),
                  style: const TextStyle(fontSize: 11, color: Colors.red)),
            ),
        ],
      ),
    );
  }

  // A customer who never saved a service address is, more often than not, a
  // contractor who signed up on the wrong side of the app. That happened to a
  // real applicant (Jose, 2026-08-04) and nothing surfaced it — his account
  // just sat there looking like an ordinary quiet customer.
  //
  // Deliberately NOT keyed on "has never ordered": it is August, we have not
  // launched, and nobody orders snow removal in ninety-degree weather — so that
  // test flags every customer we have and tells us nothing. Saving an address
  // is the thing a real customer does the moment they arrive, in any season.
  //
  // Clears once we've written to them: this is a to-do, not a label, and a
  // prompt that stays lit after you've acted on it trains you to ignore it.
  bool _looksLikeWrongSide(Map<String, dynamic> user) {
    final id = user['id']?.toString();
    if (id == null) return false;
    if (usersWithAddress.contains(id)) return false;
    if (_mailFor(userId: id, email: user['email']?.toString()).isNotEmpty) {
      return false;
    }
    return !jobs.any((j) => j['customer_id']?.toString() == id);
  }

  String _wrongSideEmailBody(Map<String, dynamic> user) {
    final first =
        (user['name'] ?? '').toString().trim().split(RegExp(r'\s+')).first;
    final pct = (AppConfig.providerFraction * 100).round();
    return 'Hi${first.isEmpty ? '' : ' $first'},\n\n'
        'You created a SnowServ account — thanks for that. I am reaching out to '
        'make sure you ended up in the right place.\n\n'
        'SnowServ has two sides: customers who order snow removal, and '
        'contractors who do the work and get paid. Your account was set up on '
        'the customer side. That is an easy one to miss on the signup screen, '
        'so I wanted to check which one you meant.\n\n'
        'If you were: just reply and say so. I will switch your account over '
        'myself — you keep the same email and password, and there is nothing to '
        'sign up for again. From there it is about five minutes to finish: your '
        'equipment, the agreement, and a bank connection for payouts.\n\n'
        'You keep $pct% of every job, there are no sign-up or monthly fees, no '
        'contract, and you choose which jobs you take. Your bank details go to '
        'Stripe, not to us — SnowServ never sees or stores your bank account or '
        'Social Security number. Stripe pays you directly and issues your 1099.\n\n'
        'And if you did mean to sign up as a customer, no problem at all — we '
        'are launching in Yonkers this winter and you are all set.\n\n'
        'Either way, just reply and let me know.\n\n'
        'Vince\nSnowServ';
  }

  // Every message we've sent this person, newest first, across all senders.
  List<Map<String, dynamic>> _mailFor({String? userId, String? email}) {
    final addr = email?.trim().toLowerCase();
    return emailLog.where((m) {
      if (userId != null && m['user_id']?.toString() == userId) return true;
      if (addr != null && addr.isNotEmpty) {
        return (m['to_email'] ?? '').toString().trim().toLowerCase() == addr;
      }
      return false;
    }).toList();
  }

  static const _templateNames = {
    'admin_freeform': 'Written by you',
    'lead_new': 'Recruiting email',
    'stalled_signup': 'Finish your registration',
    'pending_review': 'Application received',
    'out_of_area': 'Not your area yet',
  };

  /// "Aug 7" / "Aug 7, 2025" once it's not this year.
  String _shortDate(dynamic ts) {
    final d = DateTime.tryParse(ts?.toString() ?? '')?.toLocal();
    if (d == null) return '';
    final now = DateTime.now();
    final base = '${_months[d.month - 1]} ${d.day}';
    return d.year == now.year ? base : '$base, ${d.year}';
  }

  // The durable answer to "did I already write to this person?". A snackbar
  // says so for four seconds and then the record is gone — which is exactly
  // how the same person got emailed twice.
  Future<void> _showMailHistory(
      String label, List<Map<String, dynamic>> mail) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Emails to $label'),
        content: SizedBox(
          width: 520,
          child: mail.isEmpty
              ? const Text('Nothing sent yet.')
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final m in mail)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_shortDate(m['created_at'])}  ·  '
                                '${_templateNames[m['template']] ?? 'Email'}',
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: SnowServColors.inkSoft),
                              ),
                              Text((m['subject'] ?? '(no subject)').toString(),
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: SnowServColors.navy)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _userContactActions(Map<String, dynamic> user) {
    final email = (user['email'] ?? '').toString().trim();
    final mail = _mailFor(userId: user['id']?.toString(), email: email);
    return Wrap(
      spacing: 4,
      runSpacing: 0,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // Sits FIRST so the state of play reads before the actions do.
        if (mail.isNotEmpty)
          InkWell(
            onTap: () => _showMailHistory(
                (user['name'] ?? email).toString(), mail),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.mark_email_read_outlined,
                      size: 12, color: Colors.green.shade800),
                  const SizedBox(width: 4),
                  Text(
                    mail.length == 1
                        ? 'Emailed ${_shortDate(mail.first['created_at'])}'
                        : '${mail.length} emails · last '
                            '${_shortDate(mail.first['created_at'])}',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        TextButton.icon(
          onPressed: () => _composeEmail(user),
          icon: const Icon(Icons.send_outlined, size: 15),
          label: const Text('Email', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: email));
            if (!mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Copied $email')));
          },
          icon: const Icon(Icons.copy_outlined, size: 15),
          label: const Text('Copy', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
        if (_looksLikeWrongSide(user))
          TextButton.icon(
            onPressed: () => _composeEmail(user,
                subject: 'Did you mean to sign up to work?',
                body: _wrongSideEmailBody(user)),
            icon: Icon(Icons.help_outline, size: 15, color: Colors.orange.shade800),
            label: Text('Wrong side?',
                style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          ),
      ],
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
                      // Selectable so the address can always be dragged out by
                      // hand. Plain Text can't be selected on web, so the only
                      // way to get someone's email out of here was to retype it.
                      SelectableText(user['email'] ?? '',
                          style: const TextStyle(color: Colors.grey, fontSize: 13)),
                      if (user['phone'] != null) ...[
                        const SizedBox(height: 2),
                        SelectableText(user['phone'],
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
            if ((user['email'] ?? '').toString().trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              _userContactActions(user),
            ],
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

  // Case-insensitive match across name / email / phone (+ extra like "#7"). Also
  // matches a phone by digits, so "9146730400" finds "914-673-0400".
  bool _matchesSearch(String query, String? name, String? email, String? phone,
      {String extra = ''}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay =
        '${name ?? ''} ${email ?? ''} ${phone ?? ''} $extra'.toLowerCase();
    if (hay.contains(q)) return true;
    final qDigits = q.replaceAll(RegExp(r'\D'), '');
    final phoneDigits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    return qDigits.isNotEmpty && phoneDigits.contains(qDigits);
  }

  Widget _searchField(String hint, ValueChanged<String> onChanged) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: TextField(
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: SnowServColors.glacier)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: SnowServColors.glacier)),
        ),
      ),
    );
  }

  Widget _buildUsersTab() {
    final providerUserIds = providers.map((p) => p['user_id']?.toString()).toSet();
    final customers = users.where((u) => !providerUserIds.contains(u['id']?.toString())).toList();
    final flaggedCount = customers.where((u) => u['is_flagged'] == true).length;
    final suspendedCount = customers.where((u) => u['is_suspended'] == true).length;
    final shown = customers
        .where((u) => _matchesSearch(_customerSearch, u['name']?.toString(),
            u['email']?.toString(), u['phone']?.toString()))
        .toList();

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
        _searchField('Search customers by name, email, or phone',
            (v) => setState(() => _customerSearch = v)),
        // Inside the scroll view on purpose — an expandable panel above an
        // Expanded list has nowhere to grow and gets clipped unreachably,
        // which is exactly what happened on the Providers tab.
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _stormBookingsPanel(),
              _waitlistPanel(),
              _churnPanel(),
              if (customers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No customers yet.')),
                )
              else if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('No customers match “$_customerSearch”.',
                        style: const TextStyle(color: Colors.grey)),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final c in shown) _userCard(c)],
                  ),
                ),
            ],
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
    // NOTE: no early return on an empty roster. This tab used to bail out with
    // "No providers yet", which would have hidden the storm-readiness funnel and
    // the recruiting pipeline in the exact situation they exist for — zero
    // providers, pre-season, trying to sign people up.
    final pendingCount = providers.where((p) => p['registration_status'] == 'pending_review').length;
    final onDuty = providers.where((p) => p['is_online'] == true).toList();
    final offDuty = providers.where((p) => p['is_online'] != true).toList();
    bool match(Map<String, dynamic> p) => _matchesSearch(
          _providerSearch,
          p['users']?['name']?.toString(),
          p['users']?['email']?.toString(),
          p['users']?['phone']?.toString(),
          extra: '#${p['provider_number'] ?? ''}',
        );
    final onDutyShown = onDuty.where(match).toList();
    final offDutyShown = offDuty.where(match).toList();
    final noMatches = _providerSearch.trim().isNotEmpty &&
        onDutyShown.isEmpty &&
        offDutyShown.isEmpty;

    Widget buildProviderCard(Map<String, dynamic> p) {
              final isOnline = p['is_online'] == true;
              final regStatus = p['registration_status'] as String?;
              final isPending = regStatus == 'pending_review';
              final isApproved = regStatus == 'approved';

              final hasVehicle = p['has_vehicle'] == true;
              final hasSalt = p['has_salt'] == true;

              final activeJobs = _activeJobsFor(p['id'].toString());
              final completed = _completedFor(p['id'].toString());
              final earned = completed.fold<num>(0, (s, j) => s + _jobPrice(j)) * AppConfig.providerFraction;

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
                              '${p['users']?['name'] ?? 'Unknown'}${p['provider_number'] != null ? '  #${p['provider_number']}' : ''}',
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
                    // Contact the driver (call/text) — storm coordination.
                    _contactRow('Driver', p['users']?['phone'] as String?),
                    // ...and by email, which is how recruiting follow-up
                    // actually happens. An abandoned registration is a lead,
                    // and without this the address had to be copied by hand.
                    // Where we have a template (stalled signup / awaiting
                    // review) this SENDS as SnowServ rather than opening a
                    // draft — the draft is still one tap away inside. Only a
                    // free-form note to an already-approved driver falls back
                    // to the mail app.
                    _emailRow('Driver', p['users']?['email'] as String?,
                        onSend: _hasProviderTemplate(p)
                            ? () => _emailStalledSignup(p)
                            // Everyone else gets the free-form composer, which
                            // also sends as SnowServ. No provider card opens a
                            // mailto: any more.
                            : () => _composeEmail({
                                  'id': p['user_id'],
                                  'email': p['users']?['email'],
                                  'name': p['users']?['name'],
                                })),
                    const SizedBox(height: 8),
                    // Earnings (this driver's 75% take of their completed jobs).
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
                    // No ID row. Identity is verified by Stripe Connect during
                    // payout onboarding, to a standard we can't match by
                    // looking at a photo — and the verified legal name, DOB and
                    // address are readable in the Stripe Dashboard under
                    // Connected accounts. The payouts chip below is that check.
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
                    _infoRow(
                        'Coverage',
                        p['has_insurance'] == true
                            ? 'On file'
                            : 'None — provider acknowledged responsibility'),
                    if (p['has_insurance'] == true) ...[
                      _infoRow('Carrier', p['insurance_carrier']),
                      _infoRow('Policy #', p['insurance_policy']),
                      _infoRow('Expiry', p['insurance_expiry']),
                      _docViewButton('Insurance card', p['insurance_photo_url']),
                    ],
                    const SizedBox(height: 10),
                    // Payouts section — bank/ID/1099 live at Stripe now (#21), so
                    // we only surface the Connect Express onboarding status here.
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Payouts (Stripe)',
                          style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: SnowServColors.navy)),
                    ),
                    const SizedBox(height: 6),
                    _infoRow(
                        'Status',
                        p['payouts_enabled'] == true
                            ? 'Active ✓'
                            : (p['stripe_connect_id'] != null
                                ? 'Setup incomplete'
                                : 'Not started')),
                    const SizedBox(height: 14),
                    // Action buttons
                    if (isPending) ...[
                      // THREE actions, not two. "Not approved" is nearly always
                      // "one thing is wrong", which deserves a fix-and-resubmit
                      // rather than a rejection — so that is the middle button,
                      // and Decline is deliberately the quiet one.
                      SizedBox(
                        width: double.infinity,
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
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _requestChanges(p),
                              icon: const Icon(Icons.edit_note, size: 16),
                              label: const Text('Needs attention'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.orange.shade800,
                                side: BorderSide(color: Colors.orange.shade400),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () => rejectProvider(p['id']),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.red.shade700),
                            child: const Text('Decline'),
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
                          onPressed: () => _requestChanges(p),
                          icon: const Icon(Icons.edit_note, size: 16),
                          label: const Text('Needs attention'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange.shade800,
                            side: BorderSide(color: Colors.orange.shade400),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Revoke is the LAST resort, not the first tool. The
                      // realistic reason to pull an approved driver is a lapsed
                      // insurance card or a document that needs redoing — and
                      // for that "Needs attention" above tells them what to fix
                      // and lets them come back, where Revoke dumps them on a
                      // red dead-end screen with no explanation and no email.
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: () => revokeProvider(p['id']),
                          icon: const Icon(Icons.cancel_outlined, size: 14),
                          label: const Text('Revoke approval'),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.red.shade700),
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
        _searchField('Search providers by name, email, phone, or #',
            (v) => setState(() => _providerSearch = v)),
        // The storm panel and the recruiting pipeline used to sit OUTSIDE this
        // scroll view, in the fixed part of the Column. Both expand, and an
        // expanded panel had nowhere to grow — the content was simply clipped
        // and could not be scrolled to. They belong in the scrollable region.
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _stormReadinessPanel(),
              _leadsPanel(),
              if (providers.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text('No providers registered yet.',
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              else if (noMatches)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Text('No providers match “$_providerSearch”.',
                        style: const TextStyle(color: Colors.grey)),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (onDutyShown.isNotEmpty) ...[
                        _sectionHeader('On Duty (${onDutyShown.length})',
                            Colors.green.shade700),
                        ...onDutyShown.map(buildProviderCard),
                      ],
                      if (offDutyShown.isNotEmpty) ...[
                        _sectionHeader('Off Duty (${offDutyShown.length})',
                            Colors.grey.shade600),
                        ...offDutyShown.map(buildProviderCard),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // Minimum approved+payable providers before marketing to customers. Snow demand
  // is spiky and non-deferrable — a storm lands and everyone wants service in the
  // same six hours, and you cannot recruit mid-storm because everyone capable is
  // already out working. Below this, a first storm strands customers.
  static const int _kStormReadyFloor = 5;

  // "How many providers could actually work a storm right now?" — deliberately
  // NOT the headcount above it. A provider is only real if they are approved AND
  // payouts_enabled: approved-but-unpayable is the silent killer, because they
  // can accept and complete jobs and then can't be paid, which you'd discover
  // during a storm.
  Widget _stormReadinessPanel() {
    final approved =
        providers.where((p) => p['registration_status'] == 'approved').toList();
    final payable = approved.where((p) => p['payouts_enabled'] == true).toList();
    final unpayable = approved.length - payable.length;
    // Dispatch only deprioritizes 'shovel' on LARGE driveways; null/snowblower/
    // plow are all treated as capable (see dispatch_jobs). Mirror that exactly so
    // this number means the same thing the dispatcher means.
    final bigJobCapable =
        payable.where((p) => p['equipment'] != 'shovel').length;

    final Color tone;
    final String verdict;
    if (payable.isEmpty) {
      tone = Colors.red.shade700;
      verdict = 'No provider can be paid yet — a storm today would strand every order.';
    } else if (payable.length < _kStormReadyFloor) {
      tone = Colors.orange.shade800;
      verdict = 'Below the $_kStormReadyFloor-provider floor — recruit before marketing to customers.';
    } else if (bigJobCapable == 0) {
      tone = Colors.orange.shade800;
      verdict = 'Nobody payable can take a large driveway (all shovel-only).';
    } else {
      tone = SnowServColors.success;
      verdict = 'Storm-ready.';
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.ac_unit, size: 15, color: tone),
              const SizedBox(width: 6),
              Text('STORM READINESS',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: tone)),
            ],
          ),
          const SizedBox(height: 10),
          // FittedBox, not spaceAround: four figures plus three arrows overflow a
          // ~390px phone, and the admin panel is meant to be usable from the road
          // on an iPhone. scaleDown shrinks to fit instead of throwing a yellow
          // overflow stripe; on the full-width web panel it renders at 1:1.
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _tallyItem('Registered', providers.length, Colors.black54),
                  _funnelArrow(),
                  _tallyItem('Approved', approved.length, Colors.black87),
                  _funnelArrow(),
                  _tallyItem('Can be paid', payable.length, tone),
                  _funnelArrow(),
                  _tallyItem('Big driveways', bigJobCapable, Colors.black87),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(verdict,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: tone)),
          // The gap that costs real money — surfaced on its own line because it's
          // fixable with one nudge ("finish your Stripe setup") and invisible
          // otherwise.
          if (unpayable > 0) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange.shade800),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '$unpayable approved provider${unpayable == 1 ? '' : 's'} '
                    "${unpayable == 1 ? "hasn't" : "haven't"} finished payout setup — "
                    'they can take jobs but cannot be paid.',
                    style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _funnelArrow() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade400),
      );

  static const _leadStatuses = <String, String>{
    'new': 'New',
    'contacted': 'Contacted',
    'interested': 'Interested',
    'registered': 'Registered',
    // A willing contractor in a town we don't serve yet is not a dead lead —
    // he's the reason to open that town. Parking him here keeps him out of
    // "awaiting follow-up" without pretending he said no.
    'out_of_area': 'Out of area — waiting',
    'not_interested': 'Not interested',
  };

  static Color _leadStatusColor(String s) => switch (s) {
        'interested' => SnowServColors.iceBlue,
        'registered' => SnowServColors.success,
        'contacted' => Colors.orange.shade700,
        'out_of_area' => Colors.purple.shade400,
        'not_interested' => Colors.grey,
        _ => SnowServColors.navy,
      };

  Future<void> _markProviderEmailed(Map<String, dynamic> p) async {
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await supabase
          .from('providers')
          .update({'recruit_emailed_at': now}).eq('id', p['id']);
      if (!mounted) return;
      setState(() => p['recruit_emailed_at'] = now);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Marked as emailed.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    }
  }

  /// True when the server has a written template for this provider's state, so
  /// the Email button can send as SnowServ instead of opening a mail draft.
  static bool _hasProviderTemplate(Map<String, dynamic> p) =>
      p['registration_status'] == 'incomplete' ||
      p['registration_status'] == 'pending_review';

  // Same two-way choice as a lead, for a provider we owe a message: one who
  // signed up and stalled, or one waiting on our review. The branded send is
  // the one to prefer — it goes out as SnowServ rather than whatever account
  // the admin's mail app defaults to, and it records itself.
  Future<void> _emailStalledSignup(Map<String, dynamic> p) async {
    final email = (p['users']?['email'] ?? '').toString().trim();
    if (email.isEmpty) return;
    final already = p['recruit_emailed_at'] != null;
    final pending = p['registration_status'] == 'pending_review';
    final describes = pending
        ? 'confirms we have their application, tells them what happens next, '
            'and points them at payout setup.'
        : 'asks what stopped them, with current pay rates and a "Finish your '
            'registration" button.';
    // One tap lands straight on the send confirmation. Sending is the thing
    // you came here to do; the alternatives are one button away rather than a
    // sheet you have to read and choose from first.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(already
            ? 'Email them again?'
            : pending
                ? 'Email this applicant?'
                : 'Email this signup?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(already
              ? 'You have already emailed $email once. Sending again $describes'
              : 'Sends from SnowServ to $email — $describes'),
          if (!already) ...[
            const SizedBox(height: 14),
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              onPressed: () => Navigator.pop(ctx, 'mark'),
              child: const Text('Already emailed them another way? Mark as emailed',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'draft'), child: const Text('Write my own')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, 'send'), child: const Text('Send')),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'mark') return _markProviderEmailed(p);
    if (choice == 'draft') {
      await _email(email,
          subject: pending
              ? 'Your SnowServ registration'
              : 'Finishing your SnowServ provider account',
          body: _providerEmailBody(p));
      if (!mounted || p['recruit_emailed_at'] != null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Draft opened in your mail app.'),
        action: SnackBarAction(
          label: 'Mark as emailed',
          onPressed: () => _markProviderEmailed(p),
        ),
      ));
      return;
    }

    try {
      final res = await supabase.functions
          .invoke('send-lead-email', body: {'provider_id': p['id']});
      final sent = (res.data is Map) && (res.data['sent'] == 1);
      if (!mounted) return;
      if (sent) {
        setState(() => p['recruit_emailed_at'] = DateTime.now().toIso8601String());
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Sent to $email')));
      } else {
        final err = (res.data is Map) ? (res.data['error'] ?? '') : '';
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not send${err == '' ? '' : ': $err'}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send: $e')));
      }
    }
  }

  // Customers who wanted service somewhere we don't cover. This is the demand
  // side of expansion — it answers "which town next?" with evidence instead of
  // a hunch — and it had no UI at all, so the table filled up unread.
  // Standing orders waiting for the next storm. This is the only number in the
  // admin panel that looks FORWARD — every other figure is what already
  // happened. Before a storm it tells you how many jobs will land the moment
  // the snow stops, which is exactly what you need to decide whether to call
  // more drivers in.
  Widget _stormBookingsPanel() {
    final withDeicer = stormBookings.where((b) => b['salting'] == true).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SnowServColors.hairline),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: const Icon(Icons.snowing, color: SnowServColors.navy, size: 20),
          title: Text('Booked for the next storm (${stormBookings.length})',
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: SnowServColors.navy)),
          subtitle: Text(
            stormBookings.isEmpty
                ? 'Nobody has a standing order yet'
                : 'These fire automatically once the snow stops'
                    '${withDeicer > 0 ? ' · $withDeicer with deicer' : ''}',
            style: const TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
          ),
          children: [
            if (stormBookings.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'A standing order clears a property automatically once enough '
                  'snow has fallen AND stopped. Customers set it from the order '
                  'screen; nothing is charged until it fires.',
                  style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
                ),
              )
            else
              for (final b in stormBookings)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${b['addresses']?['address_line'] ?? 'Address'}'
                              '${b['addresses']?['city'] != null ? ', ${b['addresses']['city']}' : ''}',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${_bookingService(b)} · fires after '
                              '${_fmtTrigger(b['trigger_inches'])}"'
                              '${(b['last_error'] ?? '').toString().isNotEmpty ? '  ·  ⚠️ ${b['last_error']}' : ''}',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: (b['last_error'] ?? '').toString().isEmpty
                                      ? SnowServColors.inkSoft
                                      : Colors.orange.shade800),
                            ),
                          ],
                        ),
                      ),
                      Text(_customerName(b['customer_id']),
                          style: const TextStyle(
                              fontSize: 11.5, color: SnowServColors.inkSoft)),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  static String _fmtTrigger(dynamic v) =>
      (double.tryParse('${v ?? ''}') ?? 2).toStringAsFixed(0);

  static String _bookingService(Map<String, dynamic> b) =>
      switch (b['service_type']) {
        'sidewalk_driveway' => 'Sidewalk + driveway',
        'driveway' => 'Driveway',
        _ => 'Sidewalk',
      } + ((b['salting'] == true) ? ' + deicer' : '');

  Widget _waitlistPanel() {
    final byZip = <String, int>{};
    for (final w in waitlist) {
      final z = (w['zip'] ?? '').toString().trim();
      if (z.isNotEmpty) byZip[z] = (byZip[z] ?? 0) + 1;
    }
    final ranked = byZip.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SnowServColors.hairline),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: const Icon(Icons.pin_drop_outlined,
              color: SnowServColors.navy, size: 20),
          title: Text('Waiting for us to arrive (${waitlist.length})',
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: SnowServColors.navy)),
          subtitle: Text(
            ranked.isEmpty
                ? 'Nobody outside the zone has asked yet'
                : 'Top ZIP: ${ranked.first.key} (${ranked.first.value})',
            style: const TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
          ),
          children: [
            if (waitlist.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'When someone enters an address outside every zone, they land '
                  'here with their email and ZIP. Ranked by ZIP, this is the '
                  'evidence for which town to open next.',
                  style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
                ),
              )
            else ...[
              if (ranked.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in ranked.take(6))
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 4),
                          decoration: BoxDecoration(
                            color: SnowServColors.iceBlue.withOpacity(0.10),
                            border: Border.all(
                                color: SnowServColors.iceBlue.withOpacity(0.4)),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('${e.key} · ${e.value}',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: SnowServColors.iceBlue)),
                        ),
                    ],
                  ),
                ),
              ...waitlist.take(30).map((w) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: SnowServColors.surfaceSoft,
                        borderRadius: BorderRadius.circular(8),
                        border: const Border(
                            left: BorderSide(
                                color: SnowServColors.iceBlue, width: 3)),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${w['zip'] ?? '(no ZIP)'}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600, fontSize: 13.5)),
                              if ((w['email'] ?? '').toString().trim().isNotEmpty)
                                Text('${w['email']}',
                                    style: const TextStyle(
                                        fontSize: 11.5,
                                        color: SnowServColors.inkSoft)),
                              if ((w['address'] ?? '').toString().trim().isNotEmpty)
                                Text('${w['address']}',
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                        if ((w['email'] ?? '').toString().trim().isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.mail_outline, size: 18),
                            color: SnowServColors.iceBlue,
                            tooltip: 'Email — we have reached your area',
                            onPressed: () => _email(
                              w['email'].toString(),
                              subject: 'SnowServ is now serving your area',
                              body: 'Hi,\n\n'
                                  'You asked us to let you know when SnowServ '
                                  'reached your area — we are there now.\n\n'
                                  'You can book a driveway or sidewalk here:\n'
                                  'https://app.snowserv.app\n\n'
                                  'You are not charged when you order. We place a '
                                  'hold on your card, and it only becomes a real '
                                  'charge once a provider actually starts the '
                                  'work.\n\n'
                                  'Vince\nSnowServ\nsupport@snowserv.app',
                            ),
                          ),
                      ]),
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  // Why people left. Written by the optional exit survey on Delete Account and
  // read only here — a table with no reader is how the waitlist sat empty and
  // invisible for weeks.
  Widget _churnPanel() {
    if (deletionFeedback.isEmpty) return const SizedBox.shrink();
    final byReason = <String, int>{};
    for (final f in deletionFeedback) {
      final r = (f['reason'] ?? 'No reason given').toString();
      byReason[r] = (byReason[r] ?? 0) + 1;
    }
    final ranked = byReason.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final notes = deletionFeedback
        .where((f) => (f['note'] ?? '').toString().trim().isNotEmpty)
        .toList();

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SnowServColors.hairline),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: Icon(Icons.exit_to_app, color: Colors.red.shade400, size: 20),
          title: Text('Why people left (${deletionFeedback.length})',
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: SnowServColors.navy)),
          subtitle: Text(
            ranked.isEmpty ? '' : 'Most common: ${ranked.first.key}',
            style: const TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
          ),
          children: [
            for (final e in ranked)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(
                      child: Text(e.key,
                          style: const TextStyle(fontSize: 13))),
                  Text('${e.value}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.bold)),
                ]),
              ),
            if (notes.isNotEmpty) ...[
              const Divider(height: 18),
              const Text('What they said',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: SnowServColors.inkSoft)),
              for (final n in notes.take(10))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('\u201c${n['note']}\u201d',
                      style: const TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: Colors.black87)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // Recruiting pipeline, collapsed by default so it never buries the roster.
  // Lives in the Providers tab on purpose — recruiting feeds that list, and
  // during Sept/Oct outreach the funnel above is the reason to open this.
  Widget _leadsPanel() {
    // Someone who created an account and never finished is a recruiting lead
    // that happens to live in the providers table. Leaving them in the roster
    // below meant they were invisible — no badge, nothing waiting on follow-up
    // — so they surface here, where you go to work the funnel.
    final stalled = providers
        .where((p) => p['registration_status'] == 'incomplete')
        .toList();
    // "Awaiting follow-up" means NOBODY HAS WRITTEN TO THEM YET. It used to
    // count everything that wasn't 'registered' or 'not_interested', so a lead
    // you had already emailed still read as waiting on you — the number never
    // went down and stopped meaning anything.
    final open = providerLeads.where((l) => (l['status'] ?? 'new') == 'new').length +
        stalled.where((p) => p['recruit_emailed_at'] == null).length;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SnowServColors.hairline),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          leading: const Icon(Icons.groups_outlined, color: SnowServColors.navy, size: 20),
          title: Text(
              'Recruiting pipeline (${providerLeads.length + stalled.length})',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14, color: SnowServColors.navy)),
          subtitle: Text(
            open == 0
                ? 'No one waiting on follow-up'
                : '$open awaiting follow-up',
            style: const TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
          ),
          children: [
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _addLeadDialog,
                icon: const Icon(Icons.person_add_alt, size: 16),
                label: const Text('Add a lead'),
              ),
            ),
            const SizedBox(height: 4),
            if (providerLeads.isEmpty && stalled.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  'Nobody yet. Landscapers are the best source — they own trucks '
                  'and are idle December through March.',
                  style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
                ),
              )
            else ...[
              ...providerLeads.map(_leadRow),
              if (stalled.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 14, bottom: 2),
                  child: Text('Signed up but never finished',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: SnowServColors.inkSoft)),
                ),
                ...stalled.map(_stalledSignupRow),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // A stalled signup rendered as a pipeline row. Deliberately NOT a lead row:
  // there's no provider_leads record to set a status on or delete, so it gets
  // the one action that matters — email them the nudge — and nothing that
  // would imply it can be worked like a lead.
  Widget _stalledSignupRow(Map<String, dynamic> p) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    String when() {
      final raw = p['created_at']?.toString();
      final d = raw == null ? null : DateTime.tryParse(raw);
      if (d == null) return 'signed up, never finished';
      final days = DateTime.now().difference(d).inDays;
      final stamp = '${months[d.month - 1]} ${d.day}';
      return days <= 0
          ? 'signed up today, never finished'
          : 'signed up $stamp · $days day${days == 1 ? '' : 's'} with no follow-up';
    }

    final email = (p['users']?['email'] ?? '').toString().trim();
    final name = (p['users']?['name'] ?? '').toString().trim();

    String? emailedOn;
    final rawSent = p['recruit_emailed_at']?.toString();
    final sentAt = rawSent == null ? null : DateTime.tryParse(rawSent)?.toLocal();
    if (sentAt != null) emailedOn = '${months[sentAt.month - 1]} ${sentAt.day}';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: SnowServColors.surfaceSoft,
          borderRadius: BorderRadius.circular(8),
          border: const Border(left: BorderSide(color: Colors.grey, width: 3)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? '(no name)' : name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13.5)),
                  if (email.isNotEmpty)
                    Text(email,
                        style: const TextStyle(
                            fontSize: 11.5, color: SnowServColors.inkSoft)),
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(when(),
                        style: TextStyle(
                            fontSize: 10.5, color: Colors.grey.shade600)),
                  ),
                  // Without this there was nothing on screen saying whether
                  // this person had been contacted — so the same stalled
                  // signup got emailed twice.
                  if (emailedOn != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.check_circle,
                            size: 12, color: Colors.green.shade600),
                        const SizedBox(width: 4),
                        Text('Emailed $emailedOn',
                            style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.green.shade700)),
                      ]),
                    ),
                ],
              ),
            ),
            if (email.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.mail_outline, size: 18),
                color: SnowServColors.iceBlue,
                tooltip: 'Email — asks what stopped them',
                onPressed: () => _emailStalledSignup(p),
              ),
          ],
        ),
      ),
    );
  }

  Widget _leadRow(Map<String, dynamic> lead) {
    final status = (lead['status'] ?? 'new').toString();
    final color = _leadStatusColor(status);
    final subtitle = [
      lead['company'],
      lead['phone'],
      lead['email'],
      lead['zip'],
      lead['equipment'],
    ].where((v) => v != null && v.toString().trim().isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: SnowServColors.surfaceSoft,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (lead['name']?.toString().trim().isNotEmpty ?? false)
                        ? lead['name'].toString()
                        : '(no name)',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(subtitle,
                        style: const TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft)),
                  if ((lead['notes'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(lead['notes'].toString(),
                          style: const TextStyle(
                              fontSize: 11.5, fontStyle: FontStyle.italic, color: Colors.black54)),
                    ),
                  if ((lead['source'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text('via ${lead['source']}',
                          style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
                    ),
                ],
              ),
            ),
            // Working a lead is an email, so it gets a button rather than
            // making the admin select the address off the card and paste it.
            if ((lead['email'] ?? '').toString().trim().isNotEmpty)
              IconButton(
                icon: const Icon(Icons.mail_outline, size: 18),
                color: SnowServColors.iceBlue,
                tooltip: 'Email this lead',
                onPressed: () => _emailLead(lead),
              ),
            // Status is the whole point of the pipeline, so make it one tap.
            PopupMenuButton<String>(
              tooltip: 'Change status',
              onSelected: (v) => _setLeadStatus(lead, v),
              itemBuilder: (_) => _leadStatuses.entries
                  .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  border: Border.all(color: color),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_leadStatuses[status] ?? status,
                      style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.bold)),
                  Icon(Icons.arrow_drop_down, size: 15, color: color),
                ]),
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, size: 17, color: Colors.grey.shade500),
              tooltip: 'Delete lead',
              onPressed: () => _deleteLead(lead),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setLeadStatus(Map<String, dynamic> lead, String status) async {
    try {
      await supabase.from('provider_leads').update({'status': status}).eq('id', lead['id']);
      if (mounted) setState(() => lead['status'] = status);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update: $e')));
      }
    }
  }

  Future<void> _deleteLead(Map<String, dynamic> lead) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this lead?'),
        content: Text('${lead['name'] ?? 'This lead'} will be removed from the pipeline.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await supabase.from('provider_leads').delete().eq('id', lead['id']);
      loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      }
    }
  }

  Future<void> _addLeadDialog() async {
    final name = TextEditingController();
    final company = TextEditingController();
    final phone = TextEditingController();
    final email = TextEditingController();
    final zip = TextEditingController();
    final equipment = TextEditingController();
    final source = TextEditingController();
    final notes = TextEditingController();
    bool saving = false;

    Widget field(TextEditingController c, String label, {String? hint, int lines = 1}) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: c,
            maxLines: lines,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
        );

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add a lead'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  field(name, 'Name'),
                  field(company, 'Company', hint: 'e.g. Vito\'s Landscaping'),
                  field(phone, 'Phone'),
                  field(email, 'Email'),
                  field(zip, 'ZIP'),
                  field(equipment, 'Equipment', hint: 'e.g. 2 trucks w/ plows, 1 blower'),
                  // Free text, because knowing WHICH channel works is the whole
                  // point of running outreach across several at once.
                  field(source, 'Source', hint: 'landscaper call · Facebook · referral'),
                  field(notes, 'Notes', lines: 3),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: saving ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      final hasSomething = [name, company, phone, email]
                          .any((c) => c.text.trim().isNotEmpty);
                      if (!hasSomething) {
                        ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                            content: Text('Add at least a name, company, phone or email.')));
                        return;
                      }
                      setLocal(() => saving = true);
                      String? v(TextEditingController c) =>
                          c.text.trim().isEmpty ? null : c.text.trim();
                      try {
                        await supabase.from('provider_leads').insert({
                          'name': v(name),
                          'company': v(company),
                          'phone': v(phone),
                          'email': v(email),
                          'zip': v(zip),
                          'equipment': v(equipment),
                          'source': v(source) ?? 'admin',
                          'notes': v(notes),
                          'status': 'new',
                        });
                        if (ctx.mounted) Navigator.pop(ctx);
                        loadAll();
                      } catch (e) {
                        setLocal(() => saving = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx)
                              .showSnackBar(SnackBar(content: Text('Could not save: $e')));
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Add'),
            ),
          ],
        ),
      ),
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
      (sum, job) => sum + ((job['final_price'] ?? job['base_price'] ?? 0) as num) * AppConfig.providerFraction,
    );

    return Column(
      children: [
        // Earnings — the hero number (your cut) up top, then a by-storm
        // breakdown, since a snow business earns in storm bursts.
        Container(
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: SnowServColors.navy,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        'YOUR EARNINGS · ${AppConfig.commissionPct.round()}% commission',
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5)),
                  ),
                  InkWell(
                    onTap: _editCommission,
                    borderRadius: BorderRadius.circular(8),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.tune, size: 14, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Edit rate',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('\$${_platformEarnings.round()}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 40,
                      fontWeight: FontWeight.bold)),
              Text(
                  'From \$${_completedRevenue.round()} collected  ·  providers earned \$${_providerEarnings.round()}',
                  style: const TextStyle(
                      color: SnowServColors.glacier, fontSize: 13)),
            ],
          ),
        ),
        // Per-storm contribution (completed jobs clustered by active days).
        Builder(builder: (_) {
          final storms = _stormBuckets();
          if (storms.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('Earnings by storm',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: SnowServColors.navy)),
              ),
              ...storms.map((s) {
                final rev = s['revenue'] as num;
                final cut = (rev * AppConfig.platformFraction).round();
                final jobCount = s['jobs'] as int;
                return Card(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: ListTile(
                    leading:
                        const Icon(Icons.ac_unit, color: SnowServColors.iceBlue),
                    title: Text(s['label'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '$jobCount job${jobCount == 1 ? '' : 's'}  ·  \$${rev.round()} collected'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('\$$cut',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.green.shade700,
                                fontSize: 16)),
                        const Text('your cut',
                            style: TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        }),
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
                final pNum = job['providers']?['provider_number'];
                final providerName =
                    '${job['providers']?['users']?['name'] ?? 'Unknown'}${pNum != null ? '  #$pNum' : ''}';
                final providerPay = ((job['final_price'] ?? job['base_price'] ?? 0) as num) * AppConfig.providerFraction;
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

// A small green dot that gently pulses — the "live" indicator on the ticker.
// Self-contained (owns its AnimationController) so it can be dropped anywhere.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFF4CD964),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
