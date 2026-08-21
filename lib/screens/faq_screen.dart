import 'package:flutter/material.dart';
import '../theme.dart';
import '../utils/legal.dart';
import '../config/app_config.dart';

class FaqScreen extends StatefulWidget {
  // Which tab opens first: 0 = For Customers, 1 = For Providers. The provider
  // home screen passes 1 so its "Help & FAQ" entry doubles as a provider guide
  // (Getting Started / How Dispatching Works / Earnings / Using the App) without
  // needing a whole separate onboarding page — it lands right where a provider
  // needs it instead of on the customer tab.
  final int initialTab;
  const FaqScreen({super.key, this.initialTab = 0});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  @override
  void initState() {
    super.initState();
    // Pull the latest admin-set commission the moment the FAQ opens, so the
    // earnings answers always show the current split — not a value cached at
    // app start. Re-renders when it returns.
    AppConfig.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Help & FAQ'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'For Customers'),
              Tab(text: 'For Providers'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _FaqTab(sections: _customerSections),
            _FaqTab(sections: _providerSections),
          ],
        ),
      ),
    );
  }
}

class _FaqTab extends StatelessWidget {
  final List<_FaqSection> sections;
  const _FaqTab({required this.sections});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        ...sections.map((section) => _SectionWidget(section: section)),
        const SizedBox(height: 8),
        // Reachable even before login (the FAQ opens from the auth screen), so
        // this is the one policy surface a prospective user can find.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => openLegalUrl(privacyPolicyUrl),
              child: const Text('Privacy Policy', style: TextStyle(fontSize: 12, color: SnowServColors.iceBlue, fontWeight: FontWeight.w600)),
            ),
            const Text('·', style: TextStyle(color: SnowServColors.inkSoft)),
            TextButton(
              onPressed: () => openLegalUrl(termsOfServiceUrl),
              child: const Text('Terms of Service', style: TextStyle(fontSize: 12, color: SnowServColors.iceBlue, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionWidget extends StatelessWidget {
  final _FaqSection section;
  const _SectionWidget({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6),
          child: Row(
            children: [
              Container(
                width: 4, height: 18,
                decoration: BoxDecoration(
                  color: SnowServColors.iceBlue,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(section.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: SnowServColors.navy)),
            ],
          ),
        ),
        ...section.items.map((item) => _FaqTile(item: item)),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _FaqTile extends StatelessWidget {
  final _FaqItem item;
  const _FaqTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: SnowServColors.hairline),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Text(item.question,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: SnowServColors.navy)),
        children: [
          Text(item.answer,
              style: const TextStyle(
                  fontSize: 13, color: SnowServColors.ink, height: 1.5)),
        ],
      ),
    );
  }
}

class _FaqSection {
  final String title;
  final List<_FaqItem> items;
  const _FaqSection(this.title, this.items);
}

class _FaqItem {
  final String question;
  final String answer;
  const _FaqItem(this.question, this.answer);
}

// ─── CUSTOMER CONTENT ────────────────────────────────────────────────────────

// Storm tiers rendered from the LIVE admin-editable bands (app_settings.storm_bands
// via AppConfig). The FAQ used to hardcode 1.3×/1.7×/2.3×, which went stale the
// moment storm pricing was edited in the admin panel — the FAQ then contradicted
// what customers were actually charged (found 2026-07-29).
String _fmtMult(double m) =>
    m == m.roundToDouble() ? m.toStringAsFixed(0) : m.toString();

// The offer window is admin-editable (app_settings.dispatch_timeout_seconds) and
// the FAQ used to state a flat "4 minutes", which is only true until someone edits
// it — the same way the storm tiers above went stale. Rendered from the live value.
String get _offerWindow {
  final s = AppConfig.dispatchTimeoutSeconds;
  if (s % 60 == 0) {
    final m = s ~/ 60;
    return m == 1 ? '1 minute' : '$m minutes';
  }
  return '$s seconds';
}

// Highest live multiplier, for the provider earnings example.
double get _topStormMult => AppConfig.stormBands
    .map((b) => b.multiplier)
    .fold<double>(1.0, (a, b) => b > a ? b : a);

String get _stormTiers => AppConfig.stormBands.map((b) {
      final range = b.minInches == 0
          ? (b.maxInches == null ? 'Any depth' : 'Up to ${b.maxInches} inches')
          : (b.maxInches == null
              ? '${b.minInches}+ inches'
              : '${b.minInches}–${b.maxInches} inches');
      final mult = b.multiplier == 1.0
          ? 'standard price'
          : '${_fmtMult(b.multiplier)}× multiplier';
      return '$range: $mult';
    }).join('\n');

// Built at call time (not const) so the storm tiers above stay live.
List<_FaqSection> get _customerSections => [
  _FaqSection('How It Works', [
    _FaqItem(
      'What is SnowServ?',
      'SnowServ is an on-demand snow removal service. You request a job through the app, we dispatch the nearest available provider to your location, and you can track the status in real time — all without making a phone call.',
    ),
    _FaqItem(
      'How do I place an order?',
      'Add your service address, select the services you need (driveway, sidewalk, or both), choose whether you want deicer, and complete payment. Our system immediately begins finding the nearest available provider.',
    ),
    _FaqItem(
      'Can I order for someone else?',
      'Yes. On the order screen, toggle "Ordering for someone else" and enter the service address for that location. You pay through your account and the provider goes to that address.',
    ),
    _FaqItem(
      'What happens after I place an order?',
      'Your job is dispatched to the nearest available provider. Once a provider accepts, your home screen shows your place in their queue — how many jobs are ahead of yours — and you\'ll receive a notification. You can monitor the job status (Requested → Assigned → In Progress → Completed) in real time.',
    ),
    _FaqItem(
      'What if no provider is available?',
      'Your job stays in the queue. We\'ll notify you the moment a provider accepts. You can cancel any time before the job starts — and since your card isn\'t charged until a provider starts the job, you won\'t be charged.',
    ),
  ]),
  _FaqSection('Pricing & Payment', [
    _FaqItem(
      'What does it cost?',
      'You choose sidewalk only, driveway only, or both — plus an optional deicer add-on.\n\n'
          'Prices are set per service area, so the exact price for YOUR address is shown '
          'on the order screen before you pay — no estimates and no surprises. Prices may '
          'also be higher during heavy snowfall (see storm pricing below).\n\n'
          'You can check the price for your address any time from the app, and there are '
          'no contracts, subscriptions, or hidden fees.',
    ),
    _FaqItem(
      'Are there any contracts or hidden fees?',
      'No. There are no contracts, no monthly or subscription fees, and no hidden fees — you simply pay per job at the price shown before you confirm. Order only when you need snow removed.',
    ),
    _FaqItem(
      'What is storm pricing?',
      'During heavier snow, the job takes more time and effort, so prices adjust automatically based on current snow depth:\n\n$_stormTiers\n\nThe storm pricing level is always shown on the order screen before you pay.',
    ),
    // Naming the source, the location and the moment of measurement, in public,
    // BEFORE anyone is charged. A storm-pricing argument is unwinnable if the
    // only answer to "how much snow do you say fell?" is "our system decided" —
    // so this states the referee up front and points at the receipt, which
    // records the exact figure the price was computed from.
    _FaqItem(
      'Who decides how much snow fell?',
      'We do not measure it ourselves and neither side gets to argue the number after the fact. Snow depth comes from Open-Meteo, an independent weather service, read for the coordinates of YOUR service address — not a regional average and not a figure we set.\n\n'
          'It is read at the moment you order, and the exact depth used is saved with that order. Open your receipt and you will see the snow depth, the multiplier it produced, and the source, for that specific job.\n\n'
          'Because it is read the moment you order, it reflects the snow on your property at that moment. Snow that falls after you order does not change your price — the price you saw is the price you pay.',
    ),
    _FaqItem(
      'How is a booked-ahead storm job priced?',
      'A storm booking fires on its own once the snow stops, while you are most likely asleep — so it is capped. Storm pricing on a booking never exceeds ${AppConfig.stormBookingMaxSurge.toStringAsFixed(AppConfig.stormBookingMaxSurge % 1 == 0 ? 0 : 1)}× the normal rate, no matter how much snow falls. Blizzard pricing never applies to a job you booked in advance.\n\n'
          'A booking is priced on the NEW snow that fell in that storm, measured at your address by Open-Meteo; an on-demand order is priced on the snow lying on the ground when you order. Either way the figure used is recorded on your receipt.\n\n'
          'We put a hold on your card when the job is created and send you a notification with the amount. You are only actually charged once a provider starts, so you can still cancel free before then.',
    ),
    _FaqItem(
      'When am I charged?',
      'When you place an order, we put a temporary authorization hold on your card for the job amount. This reserves the funds and confirms your card is valid — but it is NOT a charge yet.\n\nYour card is only actually charged once a provider starts your job. Until then it stays a hold — so if no provider takes the job, or you cancel before a provider starts, the hold is released and you are never charged.',
    ),
    _FaqItem(
      'Why do I see a "pending" amount on my card?',
      'That is the authorization hold, not a charge. When you place an order we reserve the job amount to confirm your card, and it shows as "pending" on your statement.\n\nIt only becomes a real charge when a provider starts your job. If the order is cancelled before that, the pending hold drops off on its own, usually within a few minutes to a couple of days depending on your bank.',
    ),
    _FaqItem(
      'Can I save my payment method?',
      'Yes. After your first payment, check "Save card for future use." Your card details are stored securely through Stripe, and future orders will be one tap to pay.',
    ),
  ]),
  _FaqSection('Cancellations & Refunds', [
    _FaqItem(
      'Can I cancel my order?',
      'Yes, you can cancel from your home screen at any time before the job is marked In Progress.\n\nBecause we don\'t charge your card until a provider starts the job, canceling means your card was never charged — we simply release the authorization hold, and the pending amount drops off.',
    ),
    _FaqItem(
      'How long does a refund take?',
      'If you cancelled before the job started, no charge was ever taken — we release the authorization hold, which typically clears from your account within a few minutes to a couple of days.\n\nIn the rare case a refund is issued after your card was charged (for example, a job that couldn\'t be completed after it started), we process it instantly, but your bank takes 5–10 business days to post the credit back. That delay is on the bank\'s side, not ours.',
    ),
    _FaqItem(
      'What if the provider cancels?',
      'If a provider cancels your job, you\'ll be notified immediately and your job will be reassigned to the next nearest available provider at no extra charge.',
    ),
  ]),
  _FaqSection('Service & Quality', [
    _FaqItem(
      'Where am I in line for a provider?',
      'Providers work through their accepted jobs in order, so instead of a guessed arrival time we show you your place in line. Your home screen displays how many jobs are ahead of yours — for example "2 jobs ahead of you" — counting down to "You\'re next" as your provider finishes the jobs before you. When they start your job, the status changes to In Progress and you\'re notified. Exact timing still depends on snow conditions and how long each job ahead takes.',
    ),
    _FaqItem(
      'How do I rate my provider?',
      'After a job is completed, tap "My Orders" from the home screen. You\'ll see a star rating option on any completed job. Your feedback helps us maintain service quality.',
    ),
    _FaqItem(
      'What if I\'m not satisfied with the service?',
      'Contact us at support@snowserv.app and we\'ll make it right. Include your order details and a description of the issue.',
    ),
    _FaqItem(
      'Who\'s responsible if my property is damaged?',
      'Providers on SnowServ are independent professionals, responsible for their own work. If you believe a provider damaged your property, email support@snowserv.app right away with your job number and photos, and we\'ll help you work it out with the provider. The full details are in our Terms of Service.',
    ),
    _FaqItem(
      'Is my address information secure?',
      'Yes. Your address and payment information are stored securely. We never share your personal information with third parties beyond what is required to complete your service.',
    ),
    // "Do you do commercial?" is one of the most common questions and the app
    // had no answer anywhere. Answer it honestly rather than letting the order
    // screen imply yes: the app prices per driveway/walkway, and a parking lot
    // is priced by area and site plan under a seasonal contract. Quoting one
    // through residential pricing would be wrong in both directions.
    _FaqItem(
      'Do you handle commercial properties?',
      'No — SnowServ is residential only. We clear driveways, walkways and sidewalks at homes.\n\nWe don\'t take parking lots, apartment or condo complexes, retail plazas or office buildings. Commercial snow removal runs on seasonal contracts and carries insurance requirements that are a different business from what we do, and we\'d rather say so plainly than take your details and disappoint you later.\n\nFor a commercial property, look for a contractor who specialises in it.',
    ),
  ]),
];

// ─── PROVIDER CONTENT ─────────────────────────────────────────────────────────

// Built at call time so the commission figures always match the live,
// admin-set rate (AppConfig) — never a stale hardcoded 70/30.
List<_FaqSection> get _providerSections {
  final keep = (100 - AppConfig.commissionPct).round(); // provider %
  final comm = AppConfig.commissionPct.round(); // platform %
  final f = AppConfig.providerFraction;
  return [
  _FaqSection('Getting Started', [
    _FaqItem(
      'How do I sign up as a provider?',
      // "and insurance details" read as a flat requirement. It isn't one, and
      // stating it that way turns away the easiest provider to recruit — the
      // snowblower owner with no commercial policy, who covers the sidewalk
      // jobs. The form has always been correct; only the wording wasn't.
      'Download SnowServ, choose "I want to clear snow and get paid" on the signup screen, and complete the short registration. You tell us your equipment — a truck or plow is optional, and snowblower and shovel-only providers are welcome and get plenty of work.\n\nWe don\'t ask you for any ID. Stripe verifies your identity when you set up payouts, and SnowServ never sees or stores your bank account or Social Security number.\n\nInsurance is required only if you clear snow with a vehicle. For hand-shoveling or a snowblower it\'s recommended but not required.',
    ),
    _FaqItem(
      'How long does approval take?',
      'Our team reviews your application as quickly as possible. You\'ll receive a notification once you\'ve been approved or if any information needs correction. Once approved, you can start accepting jobs immediately.',
    ),
    _FaqItem(
      'What do I need to qualify?',
      'A bank account for payouts, set up through Stripe — that\'s it. No ID or license is collected by us; Stripe handles identity verification as part of payout setup. A vehicle is optional — you can work with just a snowblower or shovel. Liability insurance is required if you clear snow with a vehicle, and optional (but recommended) if you use hand tools. Crew size and deicer availability are helpful but not required.',
    ),
    _FaqItem(
      'How do I go online to receive jobs?',
      'Open the app and toggle the Online switch on your home screen. Make sure location services are enabled — we use your GPS to match you with nearby jobs. You\'ll receive a push notification for each new job dispatch.',
    ),
    _FaqItem(
      'How do I update my equipment if it changes?',
      'Tap the person icon in the top right, then "Equipment, Vehicle & Insurance." You can change your equipment there any time — no need to contact support. Keep it current if your snowblower breaks down, you sell your plow truck, or you upgrade — it directly affects which jobs you\'re matched to (see "How Dispatching Works" below).',
    ),
  ]),
  _FaqSection('How Dispatching Works', [
    _FaqItem(
      'How are jobs assigned to me?',
      'When a customer places an order, our system offers it to the best-matched online provider — balanced by distance, current workload, (for larger driveways) your equipment, and your rating — so it goes to a nearby, available provider who can actually do the job. You\'ll get a push notification and have $_offerWindow to accept or decline. If you don\'t respond in time, the job moves to the next best provider.\n\nRating is the last of those, not the first: among providers who are about equally close, the higher-rated one is offered the job first. See "Your Rating" below for exactly how that works.',
    ),
    _FaqItem(
      'Does my equipment affect which jobs I get?',
      'Yes, for large driveways. If you\'ve registered as "Shovel only," you\'re still eligible for every walkway, sidewalk, and small-driveway job, and you can always be offered a large driveway too if no better-equipped provider is available nearby — you\'re just not first in line for those. Snowblower and plow-truck providers are matched equally for driveways of any size. This is a soft preference, not a hard rule — a job is never left stranded over equipment. Keep your equipment updated (see "Getting Started" above) so this stays accurate.',
    ),
    _FaqItem(
      'Can I receive more than one job at a time?',
      'Yes — you\'ll get new offers even while working on your current one, so there\'s no idle time, and there\'s no hard cap on how many you line up. But dispatch is workload-aware: the more jobs you\'re already holding, the more likely a new nearby order goes to a less-busy provider first, so customers don\'t wait behind a long backlog. Take what you can genuinely get to soon and keep your queue moving to stay first in line for work in your area. Customers can see how many jobs are ahead of theirs, so finishing promptly protects their trust — and your standing.',
    ),
    _FaqItem(
      'What is auto-accept?',
      'Turn on "Auto-accept jobs while online" from your home screen and any job routed to you is accepted automatically — no offer to catch and nothing to miss while you\'re driving or clearing snow. Load-aware matching still applies, so you only get jobs suited to your location and current workload. Switch it off anytime to go back to accepting each job manually.',
    ),
    _FaqItem(
      'What happens if I decline a job?',
      'No problem — declining is always an option. The job moves to the next nearest provider. Declining occasionally is fine, but frequent declines may affect your priority in future dispatches.',
    ),
    _FaqItem(
      'What if I need to cancel a job I already accepted?',
      'We understand emergencies happen. Tap Cancel on the active job card and confirm. The customer will be notified and the job will be reassigned to another provider. Please use this sparingly — frequent cancellations after acceptance may affect your account standing.',
    ),
    _FaqItem(
      'What if a customer cancels on me?',
      'You\'ll receive a push notification if a customer cancels. Cancellations that happen before you start the job will not affect your ratings or standing.',
    ),
    // Contractors with a plow truck ask this before anything else, because
    // commercial is where their money is. Say plainly that app jobs are
    // residential so nobody signs up expecting parking lots and feels misled —
    // then point the ones with real equipment at the operator list, which is a
    // genuinely better fit for them than a $120 driveway.
    // Vince asked that providers be told to flag underpriced jobs. Without this
    // the feature is invisible: nobody opens a notes panel they were never told
    // about, and the admin's price_multiplier lever stays unused because the
    // signal never arrives.
    _FaqItem(
      'This job is bigger than the price suggests — what do I do?',
      'Do the job as booked, then leave a note on the property. On the job card, open Property notes, choose "Bigger job than priced" and say what you found — "driveway is about 200 feet, takes twice as long as a normal one", or "corner lot, sidewalk on two streets".\n\nThat note stays with the ADDRESS, not the job, so the next provider sent there sees it too — and it goes straight to us. We can raise the price on that specific property for future orders, which means the next person who clears it gets paid properly for the work it actually takes.\n\nWe can\'t change the price of a job already booked — the customer\'s card was authorized for the amount they agreed to. But telling us is how it gets fixed for next time. If a property is badly mispriced, say so; that\'s useful to us and we\'d rather know.',
    ),
    _FaqItem(
      'Do you send out commercial work — parking lots, complexes?',
      'No. Every job on SnowServ is residential — driveways, walkways and sidewalks at homes.\n\nWe don\'t take commercial contracts, so none will come to you through the app. If commercial is the part of your business you\'re trying to fill, SnowServ isn\'t the right fit for it, and it\'s better you know that before you sign up than after.\n\nWhat we do send is steady residential work in your area, matched to the equipment you have.',
    ),
  ]),
  // Rating became load-bearing on 2026-08-11 — dispatch_jobs() now sorts by it
  // inside a distance band. A number that quietly decides who gets offered work
  // has to be explained, or the first provider who notices someone else getting
  // the jobs concludes the app plays favorites. The full version is the "How
  // your rating works" screen (tap the rating chip on the home screen).
  _FaqSection('Your Rating', [
    _FaqItem(
      'What rating do I start with?',
      'Five stars. New providers are treated as a 5.0 until customers start rating them, so you begin level with our best drivers rather than working your way up from the bottom.\n\nUntil your first rating arrives, your home screen shows a dash instead of a number. That\'s normal and it doesn\'t hold you back on jobs.',
    ),
    _FaqItem(
      'Where does my rating come from?',
      'After a job is marked complete, the customer can rate it 1 to 5 stars from their Orders screen. Your rating is the average of every job of yours that got rated, to one decimal place.\n\nOnly rated jobs count, and plenty of customers never rate at all — a quiet job is not a bad job. Jobs that were cancelled, and jobs a customer called off before you started, are never rated and never affect your average.',
    ),
    _FaqItem(
      'Does my rating actually affect the jobs I get?',
      'Yes, but only in close calls — and that\'s deliberate. When an order comes in we rank online providers by equipment (for large driveways), then current workload, then distance, then rating.\n\nDistance is compared in bands rather than to the foot: everyone within about two miles of the job counts as equally close, and among those drivers the higher-rated one is offered it first.\n\nSo a 5.0 driver across town will not take a job from a 4.6 driver on the next street — that would cost the customer time and cost you fuel over a rounding difference. What a good rating wins you is the close calls. In a neighborhood where several drivers are working the same few blocks, almost every call is a close call.',
    ),
    _FaqItem(
      'How much does one bad rating hurt?',
      'It depends entirely on how many you already have. An average moves fastest when there\'s little behind it: three perfect jobs followed by one 3-star leaves you at 4.5, while fifty perfect jobs followed by that same 3-star leaves you at 5.0 — it barely registers.\n\nThat\'s the honest reason to be careful early. It\'s also why a rough patch is recoverable: a run of good work pulls an average back up, and the fewer ratings you have, the faster it climbs.',
    ),
    _FaqItem(
      'How do I protect my rating?',
      'Almost every low rating we see comes down to one of these, and none of them are about skill:\n\n• Clear everything that was paid for. The job card itemizes it — driveway, walkway, deicer. Deicer is charged separately, so skipping it is the fastest route to a 1-star and a refund request.\n\n• Read the property notes before you start. Gate codes, where not to pile the snow, which side a neighbor parks on. Those notes stay with the address, so whoever went before you may have left you the answer.\n\n• Treat the completion photo as evidence, because that\'s what it is. Wide enough to show the whole surface, taken after you finish, in enough light to see the pavement. It\'s the first thing the customer sees when the job closes.\n\n• Take the optional "before" photo when you start. Thirty seconds, and it\'s the difference between "he barely did anything" and a pair of photos that settles it.\n\n• Don\'t accept what you can\'t get to. Declining an offer costs you nothing. Accepting and then cancelling costs the customer their morning, and cancellations after you\'ve started are counted on your record.',
    ),
    _FaqItem(
      'Does my rating change how much I\'m paid?',
      'No. You keep the same $keep% of every job regardless of your rating. There\'s no star bonus and no penalty rate — rating buys you position in line, never a different cut.\n\nCustomers aren\'t shown your rating and don\'t pick their driver from a list. The system uses it on their behalf, which is why the only thing it can do is decide who gets offered a job.',
    ),
    _FaqItem(
      'I think a rating was unfair — what can I do?',
      'Email support@snowserv.app with the job ID and what happened. There\'s no cutoff number that removes you automatically; when there\'s a problem a person looks at the account — the photos, the notes, any disputes — because one angry customer isn\'t the same thing as a pattern.\n\nIf your before-and-after photos show the work was done properly, say so and point us at that job. That\'s exactly what those photos are for.',
    ),
  ]),
  _FaqSection('Earnings & Payouts', [
    _FaqItem(
      'How much do I earn per job?',
      // Deliberately a ROUND ILLUSTRATIVE number, not a real SnowServ price.
      // This said "a \$125 driveway + sidewalk job" — a specific claim about our
      // pricing that went stale the moment Yonkers moved to \$160, and would be
      // wrong in a different way in every new service area. Prices are per-zone
      // and admin-editable; any fixed figure written here is a promise that
      // decays. \$100 reads as "for the sake of the example" and never expires.
      'You keep $keep% of the total job price. The remaining $comm% covers platform fees, payment processing, insurance, and app maintenance.\n\nPrices are set per service area, so what a job pays depends on where it is — an area with bigger properties is priced higher, and your $keep% scales with it. As an example, on a \$100 job you\'d keep \$${(100 * f).toStringAsFixed(2)}.\n\nThe exact pay for every job is shown on the offer before you accept it.',
    ),
    _FaqItem(
      // Added 2026-08-20, before sales tax ever goes live, deliberately. Tax is
      // EXCLUSIVE: the customer pays the job price plus tax, so a $160 job bills
      // $174.20 in Yonkers. providerPay() and process-payout both use
      // final_price, which is the PRE-TAX amount, so a provider's cut is already
      // correct and they are never shown the tax-inclusive figure. The risk is
      // purely perceptual — a provider who hears the customer paid $174.20 and
      // divides their $120 by it gets 69%, not the 75% we recruit on, and
      // concludes they are being skimmed. Much cheaper to answer here now than
      // to rebut an accusation later.
      'Does sales tax come out of my pay?',
      // Deliberately names NO state. Tax rules and rates differ by area and this
      // answer has to stay true everywhere SnowServ opens. "The tax authority"
      // rather than "the state" because local sales tax is not always
      // state-administered (Colorado home-rule cities, Louisiana parishes).
      'No. Where sales tax applies, it is added to the customer\'s bill on top of the job price and sent to the tax authority. It is never part of the job price and it never reduces your share.\n\nYou keep $keep% of the job price, every time. On a \$100 job you are paid \$${(100 * f).toStringAsFixed(2)}, and any sales tax the customer paid on top of that goes straight to the tax authority — SnowServ keeps none of it either. If a customer ever mentions paying more than the job price, that difference is tax, not a deduction from your pay.',
    ),
    _FaqItem(
      'Are there any fees or contracts to work with SnowServ?',
      'No. There are no sign-up fees, no monthly or subscription fees, and no contract locking you in. You keep $keep% of every job; the only deduction is the $comm% platform commission, shown upfront, which covers payment processing, insurance, and app maintenance. Work as much or as little as you want.',
    ),
    _FaqItem(
      'How does storm pricing affect my pay?',
      'When it snows harder, storm pricing raises the total job price — and since you keep $keep%, your pay scales up with it automatically. The same snow-depth tiers customers see apply to your earnings:\n\n$_stormTiers\n\nExample: a job that normally bills \$100 would bill \$${(100 * _topStormMult).toStringAsFixed(0)} at the top tier (${_fmtMult(_topStormMult)}×), so your $keep% would be \$${(100 * _topStormMult * f).toStringAsFixed(2)}.',
    ),
    _FaqItem(
      'How long does it take to get paid?',
      'Payouts are processed on a 7-day rolling basis. Once a completed job is 7 or more days old, it becomes eligible for the next payout batch. Our admin team processes payouts regularly to your bank account on file.',
    ),
    _FaqItem(
      'How do I set up or update my payout information?',
      'Tap the person icon in the top right corner of your home screen, then tap "Set up / manage payouts." This opens Stripe\'s secure page, where you add or update your bank account and verify your identity. SnowServ never stores your bank details — Stripe handles it directly, and also issues your year-end 1099.',
    ),
  ]),
  _FaqSection('Using the App', [
    _FaqItem(
      'What does each job status mean?',
      'Requested — customer paid, looking for a provider\nAssigned — you\'ve accepted and are on your way\nIn Progress — you\'ve started the job on-site\nCompleted — job is done and marked complete',
    ),
    _FaqItem(
      'How do I start and complete a job?',
      '1. Accept the dispatched job from the notification or dispatch card\n2. Tap Directions on the job card to navigate to the address\n3. Tap Start Job when you arrive and begin work\n4. Tap Complete Job when finished — a live completion photo is required\n5. Your earnings are recorded and queued for payout',
    ),
    _FaqItem(
      'Should I take a photo BEFORE I start? (Protect yourself)',
      'Yes — we strongly recommend it. When you tap Start Job, you\'re offered an optional "before" photo (for example, the snowed-in driveway, deep drifts, or a car blocking access). It\'s the single best thing you can do to protect yourself: if a customer later disputes the work or the conditions, that photo shows exactly what you were dealing with when you arrived. It\'s optional and skippable, but taking it is smart — especially on big or difficult jobs.',
    ),
    _FaqItem(
      'Do I need to take completion photos?',
      'Yes — a live completion photo is required. You take it with your camera at the job (there\'s no gallery upload), so it\'s genuine proof the work was done. Pair it with the optional "before" photo (see above) and you\'ve documented the job start to finish.',
    ),
    _FaqItem(
      'Will the app navigate me to the job?',
      'Yes. Tap the Directions button on the job card and your maps app (Apple Maps or Google Maps) opens with the job\'s address as the destination. You choose when to head out — nothing opens automatically.',
    ),
    _FaqItem(
      'What happens to my status if I close the app?',
      'Your online/offline status is always reset to offline when you open the app fresh. You must toggle Online each time you start your shift. This prevents you from receiving dispatches when you\'re not actually available.',
    ),
  ]),
  _FaqSection('Support', [
    _FaqItem(
      'What if I damage a customer\'s property?',
      'As an independent contractor, you\'re responsible for the safe performance of every job — including any damage you cause. That\'s exactly why the optional "before" photo and appropriate insurance matter: they protect you. If an incident happens, tell us at support@snowserv.app right away so we can help resolve it. Your responsibilities are spelled out in the Provider Service Agreement you signed at registration.',
    ),
    _FaqItem(
      'What if I have a dispute with a customer?',
      'Contact us at support@snowserv.app with the job ID and details of the issue. We review disputes fairly and will follow up with both parties.',
    ),
    _FaqItem(
      'How do I contact support?',
      'Email us at support@snowserv.app. Include your name, the job ID if relevant, and a description of the issue. We aim to respond within 24 hours.',
    ),
  ]),
  ];
}
