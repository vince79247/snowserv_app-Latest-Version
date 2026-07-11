// Shared job-dispatch logic. Used for both the initial dispatch (when a
// customer places an order) and re-dispatch (when a provider declines or
// cancels). Previously this ~55-line block was duplicated in customer_home
// and provider_home — keeping it in one place prevents the two copies from
// drifting apart.

import 'package:supabase_flutter/supabase_flutter.dart';
import 'job_helpers.dart';

/// Finds the best eligible provider for [jobId] and dispatches to them.
///
/// Eligibility: online, approved, and not in [rejected]. Ranking is LOAD-AWARE:
/// the provider with the fewest active jobs wins first, with proximity to
/// [lat]/[lng] as the tie-breaker. This keeps any one provider from hoarding
/// the queue (so later customers don't wait behind a long backlog) while never
/// stranding a job — if everyone is busy it still goes to the least-loaded
/// provider. No hard cap: providers can stack jobs when demand genuinely
/// exceeds supply (e.g. mid-storm), they just stop being first pick once
/// someone else is freer. For a busy provider, distance is measured from their
/// current job's location (where they'll finish), otherwise from current GPS.
///
/// Does nothing if no eligible provider is available (the job stays queued).
Future<void> dispatchToNearest(
  SupabaseClient supabase,
  String jobId,
  List<dynamic> rejected,
  double? lat,
  double? lng,
) async {
  try {
    final providers = await supabase
        .from('providers')
        .select('id, user_id, current_lat, current_lng, auto_accept, preferred_until')
        .eq('is_online', true)
        .eq('registration_status', 'approved');

    // Who ordered this job — so we never dispatch it back to the same person if
    // they also happen to be a provider (ordering service for themselves).
    final jobRow = await supabase
        .from('jobs')
        .select('customer_id')
        .eq('id', jobId)
        .maybeSingle();
    final customerId = jobRow?['customer_id']?.toString();

    // Count active jobs per provider and grab their current job's location.
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
            : {
                'count': (providerActiveJob[pid]!['count'] as int) + 1,
                'job_lat': job['job_lat'],
                'job_lng': job['job_lng'],
              };
      }
    }

    // Exclude rejected providers (load-aware ranking handles balancing), and
    // never offer a job to the person who ordered it.
    final available = (providers as List).where((p) {
      if (rejected.contains(p['id'].toString())) return false;
      if (customerId != null && p['user_id']?.toString() == customerId) return false;
      return true;
    }).toList();

    if (available.isEmpty) return;

    // Provider's effective location for distance: a busy provider is measured
    // from their current job (where they'll finish), else their GPS. Returns
    // null when unknown.
    double? distOf(Map<String, dynamic> p) {
      if (lat == null || lng == null) return null;
      final info = providerActiveJob[p['id'].toString()];
      final pLat = (info != null && info['job_lat'] != null)
          ? (info['job_lat'] as num).toDouble()
          : (p['current_lat'] as num?)?.toDouble();
      final pLng = (info != null && info['job_lng'] != null)
          ? (info['job_lng'] as num).toDouble()
          : (p['current_lng'] as num?)?.toDouble();
      if (pLat == null || pLng == null) return null;
      return dist2(lat, lng, pLat, pLng);
    }

    int loadOf(Map<String, dynamic> p) =>
        (providerActiveJob[p['id'].toString()]?['count'] as int?) ?? 0;

    // Normal winner: fewest active jobs, then nearest.
    available.sort((a, b) {
      final la = loadOf(a), lb = loadOf(b);
      if (la != lb) return la.compareTo(lb);
      final da = distOf(a) ?? double.infinity;
      final db = distOf(b) ?? double.infinity;
      return da.compareTo(db);
    });
    final normalWinner = available.first;
    final normalDist = distOf(normalWinner) ?? double.infinity;

    // Nearest PREFERRED driver whose override is still live and whose distance we
    // can measure. Admin override: they win ONLY if equal-or-closer than the
    // normal winner (never sent a worse-distance job). Kept in sync with
    // dispatch_jobs() (SQL cron). Auto-expires via preferred_until.
    final nowUtc = DateTime.now().toUtc();
    Map<String, dynamic>? preferred;
    double preferredDist = double.infinity;
    for (final p in available) {
      final pu = p['preferred_until'];
      if (pu == null) continue;
      final until = DateTime.tryParse(pu.toString());
      if (until == null || !until.toUtc().isAfter(nowUtc)) continue;
      final d = distOf(p);
      if (d == null) continue; // need a known location to prove closeness
      if (d < preferredDist) {
        preferredDist = d;
        preferred = p;
      }
    }

    final chosen = (preferred != null && preferredDist <= normalDist)
        ? preferred
        : normalWinner;
    if (chosen['auto_accept'] == true) {
      // Provider is on auto-accept: assign the job straight away (no offer /
      // countdown), so they never have to watch their phone to catch it.
      await supabase.from('jobs').update({
        'status': 'assigned',
        'provider_id': chosen['id'],
        'dispatched_to': null,
        'dispatched_at': null,
        if (lat != null) 'job_lat': lat,
        if (lng != null) 'job_lng': lng,
      }).eq('id', jobId);
      // Let them know a job landed on their plate. Fire-and-forget.
      try {
        await supabase.functions
            .invoke('notify-provider', body: {'job_id': jobId, 'status': 'auto_assigned'});
      } catch (_) {}
    } else {
      await supabase.from('jobs').update({
        'dispatched_to': chosen['id'],
        'dispatched_at': DateTime.now().toUtc().toIso8601String(),
        if (lat != null) 'job_lat': lat,
        if (lng != null) 'job_lng': lng,
      }).eq('id', jobId);

      // Push a notification to only the provider we just dispatched to — never a
      // broadcast. Fire-and-forget; a failed push shouldn't undo the dispatch.
      try {
        await supabase.functions.invoke('notify-dispatch', body: {'job_id': jobId});
      } catch (_) {}
    }
  } catch (e) {
    // Swallow — a failed dispatch leaves the job queued for the next attempt.
    // ignore: avoid_print
    print('Dispatch error: $e');
  }
}
