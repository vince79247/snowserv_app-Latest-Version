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
        .select('id, current_lat, current_lng')
        .eq('is_online', true)
        .eq('registration_status', 'approved');

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

    // Exclude only rejected providers (load-aware ranking handles balancing).
    final available = (providers as List).where((p) {
      return !rejected.contains(p['id'].toString());
    }).toList();

    if (available.isEmpty) return;

    // Load-aware: fewest active jobs first, then nearest as the tie-breaker.
    available.sort((a, b) {
      final aInfo = providerActiveJob[a['id'].toString()];
      final bInfo = providerActiveJob[b['id'].toString()];
      final aCount = (aInfo?['count'] as int?) ?? 0;
      final bCount = (bInfo?['count'] as int?) ?? 0;
      if (aCount != bCount) return aCount.compareTo(bCount);
      if (lat == null || lng == null) return 0;
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
      return dist2(lat, lng, aLat, aLng).compareTo(dist2(lat, lng, bLat, bLng));
    });

    await supabase.from('jobs').update({
      'dispatched_to': available.first['id'],
      'dispatched_at': DateTime.now().toUtc().toIso8601String(),
      if (lat != null) 'job_lat': lat,
      if (lng != null) 'job_lng': lng,
    }).eq('id', jobId);

    // Push a notification to only the provider we just dispatched to — never a
    // broadcast. Fire-and-forget; a failed push shouldn't undo the dispatch.
    try {
      await supabase.functions.invoke('notify-dispatch', body: {'job_id': jobId});
    } catch (_) {}
  } catch (e) {
    // Swallow — a failed dispatch leaves the job queued for the next attempt.
    // ignore: avoid_print
    print('Dispatch error: $e');
  }
}
