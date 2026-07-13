import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

// "Report a problem" flow for a completed job. Files a row into public.disputes
// (RLS: a party to the job can insert; admin reads/resolves). Shared by the
// customer and provider job-history screens.
//
// Doubles as the App Store Guideline 1.2 mechanism to report objectionable
// content (providers upload completion photos = user-generated content).

final _supabase = Supabase.instance.client;

const _customerReasons = <String>[
  'Work was not completed',
  'Poor quality / areas missed',
  'Property was damaged',
  'Provider never showed up',
  'Wrong service performed',
  'Billing or charge issue',
  'Inappropriate photo or conduct',
  'Other',
];

const _providerReasons = <String>[
  'Could not access the property',
  'Unsafe conditions on site',
  'Customer complaint or conduct',
  'Payment / payout issue',
  'Job details were wrong',
  'Other',
];

/// A "Report a problem" button for a completed [job]. [isProvider] picks the
/// reason list and which side is filing.
Widget reportProblemButton(BuildContext context, Map<String, dynamic> job,
        {required bool isProvider}) =>
    TextButton.icon(
      onPressed: () => showDisputeDialog(context, job, isProvider: isProvider),
      icon: const Icon(Icons.flag_outlined, size: 16, color: SnowServColors.inkSoft),
      label: const Text('Report a problem',
          style: TextStyle(fontSize: 12, color: SnowServColors.inkSoft)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );

Future<void> showDisputeDialog(BuildContext context, Map<String, dynamic> job,
    {required bool isProvider}) async {
  final reasons = isProvider ? _providerReasons : _customerReasons;
  String reason = reasons.first;
  final descController = TextEditingController();
  bool submitting = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('Report a problem'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (job['job_number'] != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text('Job #${job['job_number']}',
                        style: const TextStyle(
                            fontSize: 12, color: SnowServColors.inkSoft)),
                  ),
                const Text('What went wrong?',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: reason,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: reasons
                      .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                      .toList(),
                  onChanged: (v) => setLocal(() => reason = v ?? reason),
                ),
                const SizedBox(height: 12),
                const Text('Tell us more',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: descController,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Add any details that help us resolve this…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Our team reviews every report and follows up with both sides.',
                  style: TextStyle(fontSize: 11, color: SnowServColors.inkSoft),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: submitting ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: submitting
                ? null
                : () async {
                    setLocal(() => submitting = true);
                    try {
                      await _supabase.from('disputes').insert({
                        'job_id': job['id'],
                        'customer_id': job['customer_id'],
                        'provider_id': job['provider_id'],
                        'reason': reason,
                        'description': descController.text.trim(),
                        'status': 'pending',
                      });
                      if (!ctx.mounted) return;
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Report submitted. Our team will follow up — you can also '
                              'reach us at support@snowserv.app.'),
                          duration: Duration(seconds: 6),
                        ),
                      );
                    } catch (e) {
                      setLocal(() => submitting = false);
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('Could not submit: $e'),
                            backgroundColor: Colors.red),
                      );
                    }
                  },
            child: submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Submit report'),
          ),
        ],
      ),
    ),
  );
}
