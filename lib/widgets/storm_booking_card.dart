import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_config.dart';
import '../theme.dart';

// "Book my next storm" — a standing order that fires itself when snow STOPS.
//
// Vince's idea, and his framing of it: "definitely so they could book ahead of
// time FOR WHEN THE STORM IS DONE." That's the product. Nobody wants plowing at
// hour two of a ten-hour storm; they want to wake up to a clear driveway. The
// server checks both conditions — enough snow fell AND it has stopped — before
// creating the job.
//
// ON-DEMAND IS STILL THE PITCH (his call, and the right one). This is a card
// underneath the order flow, never the headline. The differentiator is "order
// it now, watch it happen"; this just captures the overnight case that
// on-demand alone can't serve, because nobody is awake at 4am to tap Order.
//
// Payment is NOT taken here. The card on file is authorized when the booking
// actually fires, at that day's prices — a Stripe hold dies in ~7 days and
// storms don't schedule themselves.

final _supabase = Supabase.instance.client;

class StormBookingCard extends StatefulWidget {
  /// The customer's saved address this booking would cover.
  final String? addressId;
  final String addressLabel;

  /// Current order-screen selection, so booking mirrors what they're looking at.
  final String serviceType;
  final bool salting;

  /// True when the customer has a card on file — required, since we authorize
  /// off-session at trigger time with no chance to prompt them.
  final bool hasCard;
  /// e.g. "VISA •••• 4242" — shown so the customer knows exactly what gets
  /// charged while they're asleep. This is the ONE place the saved card is
  /// genuinely used, so it is the one place worth naming it.
  final String? cardLabel;

  const StormBookingCard({
    super.key,
    required this.addressId,
    required this.addressLabel,
    required this.serviceType,
    required this.salting,
    required this.hasCard,
    this.cardLabel,
  });

  @override
  State<StormBookingCard> createState() => _StormBookingCardState();
}

class _StormBookingCardState extends State<StormBookingCard> {
  Map<String, dynamic>? _booking;
  bool _loading = true;
  bool _busy = false;
  double _triggerInches = 2;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StormBookingCard old) {
    super.didUpdateWidget(old);
    if (old.addressId != widget.addressId) _load();
  }

  Future<void> _load() async {
    if (widget.addressId == null) {
      if (mounted) setState(() { _booking = null; _loading = false; });
      return;
    }
    try {
      final row = await _supabase
          .from('storm_bookings')
          .select()
          .eq('address_id', widget.addressId!)
          .eq('status', 'active')
          .maybeSingle();
      if (mounted) setState(() { _booking = row; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _book() async {
    if (widget.addressId == null) return;
    setState(() => _busy = true);
    try {
      final uid = _supabase.auth.currentUser!.id;
      final row = await _supabase.from('storm_bookings').insert({
        'customer_id': uid,
        'address_id': widget.addressId,
        'service_type': widget.serviceType,
        'salting': widget.salting,
        'trigger_inches': _triggerInches,
      }).select().single();
      if (!mounted) return;
      setState(() { _booking = row; _busy = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Booked. We\'ll clear your property once '
            '${_triggerInches.toStringAsFixed(0)}" has fallen and the snow stops.'),
        backgroundColor: SnowServColors.success,
        duration: const Duration(seconds: 5),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not book: $e')));
    }
  }

  Future<void> _cancel() async {
    final b = _booking;
    if (b == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel storm booking?'),
        content: const Text(
          'We won\'t automatically send anyone for the next storm. You can '
          'still order any time, and you can book again later.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _busy = true);
    try {
      await _supabase
          .from('storm_bookings')
          .update({'status': 'cancelled'}).eq('id', b['id']);
      if (!mounted) return;
      setState(() { _booking = null; _busy = false; });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Storm booking cancelled.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel: $e')));
    }
  }

  String get _serviceLabel => switch (widget.serviceType) {
        'sidewalk_driveway' => 'Sidewalk + driveway',
        'driveway' => 'Driveway',
        _ => 'Sidewalk',
      };

  @override
  Widget build(BuildContext context) {
    if (_loading || widget.addressId == null) return const SizedBox.shrink();
    final booked = _booking != null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: booked ? SnowServColors.success.withValues(alpha: 0.07) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: booked
                ? SnowServColors.success.withValues(alpha: 0.5)
                : SnowServColors.glacier),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(booked ? Icons.check_circle : Icons.snowing,
                  size: 18,
                  color: booked ? SnowServColors.success : SnowServColors.navy),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  booked ? 'Your next storm is booked' : 'Book my next storm',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: booked ? SnowServColors.success : SnowServColors.navy),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (booked) ...[
            Text(
              '${_bookedService(_booking!)} at ${widget.addressLabel}\n'
              'We\'ll come once ${_fmtInches(_booking!['trigger_inches'])}" has '
              'fallen and the snow has stopped.',
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 6),
            const Text(
              'Nothing is charged until it actually snows. You\'ll get a '
              'notification when we send someone.',
              style: TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _busy ? null : _cancel,
              style: TextButton.styleFrom(
                  foregroundColor: Colors.red.shade700,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 34)),
              child: const Text('Cancel this booking'),
            ),
          ] else ...[
            const Text(
              'Don\'t want to wake up and order at 5am? We\'ll send someone '
              'automatically — and we wait until the storm has actually '
              'stopped, so your driveway doesn\'t just fill back in.',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 14),
            // The slider is a MINIMUM, not a timer, and the old label ("Come
            // after ___") never said which. Vince read it in build 23 and
            // couldn't tell what it controlled: the paragraph above promises we
            // come when the snow stops, then a number of inches appears with no
            // stated relationship to it.
            //
            // Both conditions really do have to be true (see
            // trigger-storm-bookings): at least this much NEW snow fell, AND it
            // has stopped. So this is the "don't bother for a dusting" dial —
            // framed here as what it protects the customer from, which is being
            // charged for a storm that barely happened.
            const Text('Skip small snowfalls',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              'Only send someone if at least this much falls. Less than that '
              'and we don\'t come, and you\'re not charged.',
              style: TextStyle(
                  fontSize: 11.5, color: Colors.grey.shade600, height: 1.35),
            ),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _triggerInches,
                    min: 1,
                    max: 12,
                    divisions: 11,
                    label: '${_triggerInches.toStringAsFixed(0)}"',
                    onChanged: (v) => setState(() => _triggerInches = v),
                  ),
                ),
                Text('${_triggerInches.toStringAsFixed(0)}"',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            Text(
              '$_serviceLabel${widget.salting ? ' + deicer' : ''} · '
              '${widget.addressLabel}',
              style: const TextStyle(fontSize: 12, color: SnowServColors.inkSoft),
            ),
            const SizedBox(height: 6),
            // Said plainly, because "we'll charge your card automatically at
            // some unknown future time" is exactly the kind of thing people
            // feel tricked by if it's buried.
            //
            // The CAP is the part that earns this feature the right to charge a
            // sleeping customer. On demand you see the storm multiplier and can
            // decline it; a booking fires at 4am and authorizes the card
            // off-session, so the ceiling is what stands in for that consent —
            // and it is the honest reason to book ahead, which is why it is
            // stated here rather than in the FAQ.
            Text(
              'Nothing is charged now. When it snows we put a hold on the card '
              'on file at that day\'s price — never more than '
              '${AppConfig.stormBookingMaxSurge.toStringAsFixed(
                      AppConfig.stormBookingMaxSurge % 1 == 0 ? 0 : 1)}× '
              'the normal rate, so blizzard pricing never applies to a booking. '
              'You\'re only charged once a provider starts, and you can cancel '
              'free before then.',
              style: const TextStyle(fontSize: 11.5, color: SnowServColors.inkSoft),
            ),
            const SizedBox(height: 10),
            if (!widget.hasCard)
              const Text(
                'Add a card first — place any order once and we\'ll save it.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              )
            else ...[
              if (widget.cardLabel != null) ...[
                Row(
                  children: [
                    Icon(Icons.credit_card, size: 15, color: Colors.grey.shade600),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'We\'ll charge ${widget.cardLabel} when it fires.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : _book,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SnowServColors.navy,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Book my next storm'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _fmtInches(dynamic v) {
    final d = double.tryParse('${v ?? ''}') ?? 2;
    return d.toStringAsFixed(0);
  }

  static String _bookedService(Map<String, dynamic> b) => switch (b['service_type']) {
        'sidewalk_driveway' => 'Sidewalk + driveway',
        'driveway' => 'Driveway',
        _ => 'Sidewalk',
      } + ((b['salting'] == true) ? ' + deicer' : '');
}
