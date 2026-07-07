import 'package:flutter/material.dart';
import '../theme.dart';
import '../utils/legal.dart';

class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
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
        body: const TabBarView(
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
              child: const Text('Privacy Policy', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            const Text('·', style: TextStyle(color: Colors.grey)),
            TextButton(
              onPressed: () => openLegalUrl(termsOfServiceUrl),
              child: const Text('Terms of Service', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
        side: BorderSide(color: Colors.grey.shade200),
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
                  fontSize: 13, color: Colors.black87, height: 1.5)),
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

const _customerSections = [
  _FaqSection('How It Works', [
    _FaqItem(
      'What is SnowServ?',
      'SnowServ is an on-demand snow removal service. You request a job through the app, we dispatch the nearest available provider to your location, and you can track the status in real time — all without making a phone call.',
    ),
    _FaqItem(
      'How do I place an order?',
      'Add your service address, select the services you need (driveway, sidewalk, or both), choose whether you want salting, and complete payment. Our system immediately begins finding the nearest available provider.',
    ),
    _FaqItem(
      'Can I order for someone else?',
      'Yes. On the order screen, toggle "Ordering for someone else" and enter the service address for that location. You pay through your account and the provider goes to that address.',
    ),
    _FaqItem(
      'What happens after I place an order?',
      'Your job is dispatched to the nearest available provider. Once a provider accepts, you\'ll see an estimated arrival time on your home screen and receive a notification. You can monitor the job status (Requested → Assigned → In Progress → Completed) in real time.',
    ),
    _FaqItem(
      'What if no provider is available?',
      'Your job stays in the queue. We\'ll notify you the moment a provider accepts. You can cancel any time before the job starts — and since your card isn\'t charged until a provider starts the job, you won\'t be charged.',
    ),
  ]),
  _FaqSection('Pricing & Payment', [
    _FaqItem(
      'What does it cost?',
      'Sidewalk clearing: \$50\nDriveway clearing: \$100\nSidewalk + Driveway: \$125\nSalting add-on: +\$40\n\nPrices vary by service area, and may be higher during heavy snowfall (see storm pricing below).',
    ),
    _FaqItem(
      'Are there any contracts or hidden fees?',
      'No. There are no contracts, no monthly or subscription fees, and no hidden fees — you simply pay per job at the price shown before you confirm. Order only when you need snow removed.',
    ),
    _FaqItem(
      'What is storm pricing?',
      'During heavier snow, the job takes more time and effort, so prices adjust automatically based on current snow depth:\n\nUp to 3 inches: standard price\n3–6 inches: 1.3× multiplier\n6–10 inches: 1.7× multiplier\n10+ inches: 2.3× multiplier\n\nThe storm pricing level is always shown on the order screen before you pay.',
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
      'Yes, you can cancel from your home screen at any time before the job is marked In Progress.\n\nBecause we don\'t charge your card until a provider starts the job, cancelling means your card was never charged — we simply release the authorization hold, and the pending amount drops off.',
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
      'How long until a provider arrives?',
      'After a provider accepts your job, you\'ll see an estimated arrival time on your home screen. Actual arrival depends on the provider\'s distance and road conditions.',
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
      'Is my address information secure?',
      'Yes. Your address and payment information are stored securely. We never share your personal information with third parties beyond what is required to complete your service.',
    ),
  ]),
];

// ─── PROVIDER CONTENT ─────────────────────────────────────────────────────────

const _providerSections = [
  _FaqSection('Getting Started', [
    _FaqItem(
      'How do I sign up as a provider?',
      'Download SnowServ, select "I\'m a Provider" on the signup screen, and complete the registration form. You\'ll need to provide your personal information, driver\'s license, vehicle details, insurance information, and banking details for payouts.',
    ),
    _FaqItem(
      'How long does approval take?',
      'Our team reviews your application as quickly as possible. You\'ll receive a notification once you\'ve been approved or if any information needs correction. Once approved, you can start accepting jobs immediately.',
    ),
    _FaqItem(
      'What do I need to qualify?',
      'You need a valid driver\'s license, a vehicle capable of snow removal, active liability insurance, and a bank account for payouts. Crew size and salt availability are helpful but not required.',
    ),
    _FaqItem(
      'How do I go online to receive jobs?',
      'Open the app and toggle the Online switch on your home screen. Make sure location services are enabled — we use your GPS to match you with nearby jobs. You\'ll receive a push notification for each new job dispatch.',
    ),
  ]),
  _FaqSection('How Dispatching Works', [
    _FaqItem(
      'How are jobs assigned to me?',
      'When a customer places an order, our system offers it to the best-matched online provider — balanced by both distance and current workload, so it goes to a nearby provider with the fewest jobs already lined up. You\'ll get a push notification and have 4 minutes to accept or decline. If you don\'t respond in time, the job moves to the next best provider.',
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
  ]),
  _FaqSection('Earnings & Payouts', [
    _FaqItem(
      'How much do I earn per job?',
      'You keep 70% of the total job price. The remaining 30% covers platform fees, payment processing, insurance, and app maintenance.\n\nExample: A \$125 driveway + sidewalk job pays you \$87.50.',
    ),
    _FaqItem(
      'Are there any fees or contracts to work with SnowServ?',
      'No. There are no sign-up fees, no monthly or subscription fees, and no contract locking you in. You keep 70% of every job; the only deduction is the 30% platform commission, shown upfront, which covers payment processing, insurance, and app maintenance. Work as much or as little as you want.',
    ),
    _FaqItem(
      'How does storm pricing affect my pay?',
      'When it snows harder, storm pricing raises the total job price — and since you keep 70%, your pay scales up with it automatically. The same snow-depth tiers customers see apply to your earnings:\n\nUp to 3 inches: standard price\n3–6 inches: 1.3× multiplier\n6–10 inches: 1.7× multiplier\n10+ inches: 2.3× multiplier\n\nExample: a \$125 job during a 2.3× storm bills at \$287.50, so your 70% is \$201.25.',
    ),
    _FaqItem(
      'How long does it take to get paid?',
      'Payouts are processed on a 7-day rolling basis. Once a completed job is 7 or more days old, it becomes eligible for the next payout batch. Our admin team processes payouts regularly to your bank account on file.',
    ),
    _FaqItem(
      'How do I update my banking information?',
      'Tap the person icon in the top right corner of your home screen, then tap "Update Banking Details." You can update your routing and account number at any time. Keep your information current to avoid payout delays.',
    ),
  ]),
  _FaqSection('Using the App', [
    _FaqItem(
      'What does each job status mean?',
      'Requested — customer paid, looking for a provider\nAssigned — you\'ve accepted and are on your way\nIn Progress — you\'ve started the job on-site\nCompleted — job is done and marked complete',
    ),
    _FaqItem(
      'How do I start and complete a job?',
      '1. Accept the dispatched job from the notification or dispatch card\n2. Drive to the address (maps open automatically after your previous job completes)\n3. Tap Start Job when you arrive and begin work\n4. Tap Complete Job when finished — you can add photos and notes\n5. Your earnings are recorded and queued for payout',
    ),
    _FaqItem(
      'Do I need to upload completion photos?',
      'Yes — photos are required. You cannot mark a job complete without uploading at least one photo of the finished work. This protects you in the event of a dispute and gives customers confidence in the service.',
    ),
    _FaqItem(
      'Will the app navigate me to the job?',
      'Yes. After you complete a job, if you have another job already queued, Apple Maps (or Google Maps) will open automatically with the next job\'s address as the destination.',
    ),
    _FaqItem(
      'What happens to my status if I close the app?',
      'Your online/offline status is always reset to offline when you open the app fresh. You must toggle Online each time you start your shift. This prevents you from receiving dispatches when you\'re not actually available.',
    ),
  ]),
  _FaqSection('Support', [
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
