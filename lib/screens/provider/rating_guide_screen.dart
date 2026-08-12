import 'package:flutter/material.dart';
import '../../theme.dart';

/// Explains the star rating to PROVIDERS: where the number comes from, what it
/// actually changes in dispatch, and how to protect it.
///
/// This exists because rating became load-bearing on 2026-08-11 (dispatch now
/// sorts by it inside a distance band). Before that it was collected and shown
/// and did nothing, so nobody needed to explain it. A number that quietly
/// decides who gets offered work, with no explanation anywhere, reads as
/// arbitrary the first time a provider notices someone else getting the jobs.
///
/// Every mechanic described here is checked against dispatch_jobs() and the
/// rate_job RPC. If either changes, this screen changes with it — vague copy
/// ("work hard and you'll get more jobs") would age better but is worth less.
class RatingGuideScreen extends StatelessWidget {
  final double? rating;
  final int? totalJobs;
  const RatingGuideScreen({super.key, this.rating, this.totalJobs});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SnowServColors.frost,
      appBar: AppBar(title: const Text('How Your Rating Works')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: [
          _yourRatingCard(),
          const SizedBox(height: 20),
          const _Section(
            icon: Icons.star_outline,
            title: 'You start at five stars',
            paragraphs: [
              'New providers are treated as a 5.0 until customers start rating '
                  'them. You are not working your way up from the bottom — you '
                  'begin level with our best drivers, and it is yours to keep.',
              'Until your first rating comes in, your home screen shows a dash '
                  'instead of a number. That is normal, and it does not hold you '
                  'back on jobs.',
            ],
          ),
          const _Section(
            icon: Icons.rate_review_outlined,
            title: 'Where the number comes from',
            paragraphs: [
              'After a job is marked complete, the customer can give it 1 to 5 '
                  'stars from their Orders screen. Your rating is the average of '
                  'every job of yours that got rated, to one decimal place.',
              'Only rated jobs count, and plenty of customers never rate at all — '
                  'a quiet job is not a bad job. Jobs that were cancelled, and jobs '
                  'a customer called off before you started, are never rated and '
                  'never touch your average.',
            ],
          ),
          const _Section(
            icon: Icons.alt_route,
            title: 'What it actually changes',
            paragraphs: [
              'When an order comes in, we look at every approved provider who is '
                  'online, and rank them in this order:',
            ],
            bullets: [
              'Equipment — shovel-only providers go last for large driveways '
                  'only, and are first in line for everything else.',
              'Current workload — whoever is holding fewer active jobs.',
              'Distance — but in bands, not to the foot. Everyone within about '
                  'two miles of the job counts as equally close.',
              'Rating — among those equally close drivers, the higher-rated one '
                  'is offered the job first.',
            ],
            footer:
                'So rating does not beat distance across town. A 5.0 driver ten '
                'minutes away will not take a job from a 4.6 driver on the next '
                'street — that would cost the customer time and cost you fuel '
                'over a rounding difference. What rating wins is the close calls. '
                'In a neighborhood where several drivers are working the same few '
                'blocks, almost every call is a close call.',
          ),
          const _Section(
            icon: Icons.trending_up,
            title: 'Your first jobs count the most',
            paragraphs: [
              'An average moves fastest when there is little behind it. Three '
                  'perfect jobs followed by one 3-star leaves you at 4.5. Fifty '
                  'perfect jobs followed by that same 3-star leaves you at 5.0 — '
                  'it barely registers.',
              'That cuts both ways, and it is the honest reason to be careful '
                  'early: the jobs you do in your first couple of weeks set a '
                  'number you will carry for a long time. It also means a rough '
                  'patch is recoverable. A run of good work pulls an average back '
                  'up, and the fewer ratings you have, the faster it climbs.',
            ],
          ),
          const _Section(
            icon: Icons.checklist_rtl,
            title: 'What moves it, in practice',
            paragraphs: [
              'Ratings are rarely about skill. Almost every low one we see comes '
                  'down to something on this list:',
            ],
            bullets: [
              'Clear everything that was paid for. The job card itemizes it — '
                  'driveway, walkway, deicer. Deicer is charged separately, so '
                  'skipping it is the fastest way to a 1-star and a refund '
                  'request. If the card says deicer, the customer paid for it.',
              'Read the property notes before you start. Gate codes, where not '
                  'to pile the snow, which side the elderly neighbor parks on. '
                  'Those notes stay with the address, so whoever went before you '
                  'may have left you the answer already.',
              'Treat the completion photo as evidence, because that is exactly '
                  'what it is. Wide enough to show the whole surface, taken after '
                  'you finish, in enough light to see the pavement. It is the '
                  'first thing the customer sees when the job closes.',
              'Take the optional "before" photo when you start. It costs thirty '
                  'seconds and it is the difference between "he barely did '
                  'anything" and a pair of photos that settles the question.',
              'Do not accept what you cannot get to. Declining an offer costs '
                  'you nothing at all. Accepting it and cancelling costs the '
                  'customer their morning — and cancellations after you have '
                  'started are counted on your record.',
              'Finish promptly once you accept. Customers can see how many jobs '
                  'are ahead of theirs, and a long wait gets rated even when the '
                  'work is good.',
            ],
          ),
          const _Section(
            icon: Icons.payments_outlined,
            title: 'What it does not change',
            paragraphs: [
              'Your pay. You keep the same share of every job no matter what your '
                  'rating is. There is no star bonus and no penalty rate — rating '
                  'buys you position in line, never a different cut.',
              'Customers are not shown your rating and do not pick their driver '
                  'from a list. The system uses it on their behalf, which is why '
                  'the only thing it can do is decide who gets offered the job.',
            ],
          ),
          const _Section(
            icon: Icons.shield_outlined,
            title: 'If your rating slips',
            paragraphs: [
              'There is no cutoff number that removes you automatically. A person '
                  'looks at the account — the photos, the notes, any disputes — '
                  'because one angry customer is not the same thing as a pattern, '
                  'and no algorithm can tell those apart.',
              'If we do suspend an account, it stops receiving job offers '
                  'immediately. That is reserved for real problems, and we tell '
                  'you why.',
              'If you think a rating was unfair, email us. We would rather hear '
                  'about it than have you assume the number is stuck.',
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: SnowServColors.iceBlue.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SnowServColors.glacier),
            ),
            child: const Row(
              children: [
                Icon(Icons.email_outlined, color: SnowServColors.iceBlue),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Questions about your rating? Email support@snowserv.app and '
                    'a person will look at your account.',
                    style: TextStyle(fontSize: 14, color: SnowServColors.navyMid),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Only rendered when we were handed the provider's own numbers (i.e. opened
  /// from the home screen chip). Showing "—" here to somebody who arrived from
  /// the account menu would look like a failed load.
  Widget _yourRatingCard() {
    if (rating == null && totalJobs == null) return const SizedBox.shrink();
    final rated = rating != null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: SnowServColors.snow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SnowServColors.glacier),
      ),
      child: Row(
        children: [
          Icon(Icons.star, color: rated ? Colors.amber : SnowServColors.glacier, size: 34),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  rated ? rating!.toStringAsFixed(1) : 'Not rated yet',
                  style: TextStyle(
                    fontSize: rated ? 26 : 18,
                    fontWeight: FontWeight.bold,
                    color: SnowServColors.navy,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  !rated
                      ? 'You are treated as a 5.0 until customers rate you'
                      : (totalJobs != null && totalJobs! > 0)
                          ? 'Your rating across $totalJobs completed ${totalJobs == 1 ? 'job' : 'jobs'}'
                          : 'Your current rating',
                  style: const TextStyle(fontSize: 13, color: SnowServColors.inkSoft),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> paragraphs;
  final List<String> bullets;
  final String? footer;

  const _Section({
    required this.icon,
    required this.title,
    this.paragraphs = const [],
    this.bullets = const [],
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: SnowServColors.snow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SnowServColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: SnowServColors.iceBlue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: SnowServColors.navy,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final p in paragraphs) ...[
            Text(
              p,
              style: const TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: SnowServColors.ink,
              ),
            ),
            const SizedBox(height: 10),
          ],
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6, right: 10),
                    child: Icon(Icons.circle, size: 6, color: SnowServColors.iceBluLight),
                  ),
                  Expanded(
                    child: Text(
                      b,
                      style: const TextStyle(
                        fontSize: 14.5,
                        height: 1.45,
                        color: SnowServColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (footer != null)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SnowServColors.surfaceSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                footer!,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: SnowServColors.navyMid,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
