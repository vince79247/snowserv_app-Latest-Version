import 'package:flutter/material.dart';
import '../../theme.dart';

/// Bump this when the agreement text materially changes. Stored alongside a
/// provider's signature so we know which version they accepted.
const String kProviderAgreementVersion = '1.0';

class _Clause {
  final String heading;
  final List<String> body; // lines starting with "• " render as bullets
  const _Clause(this.heading, this.body);
}

const String _intro =
    'This Provider Service Agreement is between SnowServ (the "Platform," operated '
    'by [Company Legal Name]) and you, the individual or entity registering as a '
    'service provider. By signing, you agree to these terms as a condition of '
    'accepting jobs through SnowServ.';

const List<_Clause> _clauses = [
  _Clause('1. Independent Contractor Status', [
    'You are an independent contractor, not an employee, agent, or partner of SnowServ. '
        'You control how you perform services, supply your own equipment, and are responsible '
        'for your own taxes, insurance, and expenses. SnowServ operates a technology platform '
        'that connects you with customers; it does not perform the services itself.',
  ]),
  _Clause('2. Eligibility & Ongoing Requirements', [
    'You represent that you are at least 18 and legally authorized to work; hold all licenses '
        'and permits required to perform snow-removal services in your area; maintain valid '
        'liability insurance (and valid registration/auto insurance if you use a vehicle) the '
        'entire time you are on the Platform; and keep your provider profile accurate. You '
        'authorize SnowServ to verify your identity, documents, and background.',
  ]),
  _Clause('3. Performing Jobs', [
    'You agree to perform accepted jobs promptly, safely, and professionally; complete the '
        'services described in each job; communicate through the Platform; and treat customers '
        'and their property with care. You will not subcontract a job to anyone SnowServ has not '
        'approved. Repeated cancellations or no-shows may result in removal.',
  ]),
  _Clause('4. Non-Circumvention & Non-Solicitation', [
    'This is a material term. Customers you meet through SnowServ are introduced to you by, and '
        'belong to, the Platform. While you are a provider and for twelve (12) months after your '
        'last job on the Platform, you will NOT, directly or indirectly:',
    '• solicit, encourage, or arrange for any SnowServ customer to obtain snow-removal or '
        'related services from you outside the Platform;',
    '• accept or perform off-Platform work for any customer first introduced to you through '
        'SnowServ, whether or not you initiated contact;',
    '• give a customer your personal contact information, or collect a customer\'s, to arrange '
        'work outside the Platform; or',
    '• divert, or attempt to divert, any customer, lead, or opportunity away from the Platform.',
    'A customer contacting you directly does not waive this section. If a SnowServ customer asks '
        'you to work off-Platform, you must decline and direct them to book through the app.',
  ]),
  _Clause('5. No Off-Platform Transactions', [
    'All jobs sourced through SnowServ must be booked, performed, and paid through the Platform. '
        'You will not request, accept, or arrange cash or other direct payment from a SnowServ '
        'customer for any job. Accepting off-Platform payment is a material breach.',
  ]),
  _Clause('6. Customer Information & Confidentiality', [
    'Customer names, addresses, contact details, and job details are confidential and provided '
        'to you solely to complete the specific assigned job. You will not store, copy, share, '
        'sell, or reuse customer information for any other purpose, including marketing or '
        'building your own client list. These obligations survive termination.',
  ]),
  _Clause('7. Fees, Commission & Payouts', [
    'SnowServ retains a Platform commission (currently 30%) and pays you the remainder '
        '(currently 70%) of the job price. Payouts are made on a rolling batch (currently every '
        '7 days) to the bank account on file. Commission and payout terms may change with notice '
        'through the app. You are responsible for all taxes on your earnings.',
  ]),
  _Clause('8. Payment Timing', [
    'The customer\'s card is authorized when they order and charged when you start the job. If a '
        'customer cancels before you start, no charge is made and you earn nothing for that job. '
        'Payment for completed work is included in the next payout batch.',
  ]),
  _Clause('9. Term & Termination', [
    'This Agreement begins when you sign it and continues until terminated. Either party may '
        'terminate at any time. SnowServ may suspend or remove you immediately for breach, safety '
        'concerns, fraud, or repeated complaints. Sections 4, 5, 6, 10, and 12–14 survive '
        'termination.',
  ]),
  _Clause('10. Consequences of Breach', [
    'If you breach Section 4, 5, or 6, SnowServ may, in addition to any other remedy: remove you '
        'from the Platform; withhold and forfeit any pending payouts to the extent permitted by '
        'law; and recover damages, including the commission it would have earned on diverted '
        'jobs. You acknowledge such breaches cause harm that is hard to quantify and that '
        'SnowServ may seek injunctive relief.',
  ]),
  _Clause('11. Insurance & Liability', [
    'You are solely responsible for the safe performance of every job and for any injury, '
        'property damage, or loss arising from your work. You will maintain the insurance '
        'required by law and by Section 2. SnowServ is not liable for your acts or omissions.',
  ]),
  _Clause('12. Indemnification', [
    'You will indemnify and hold harmless SnowServ and its owners, officers, and affiliates from '
        'any claim, loss, or expense (including reasonable attorneys\' fees) arising out of your '
        'services, your breach of this Agreement, or your violation of any law.',
  ]),
  _Clause('13. Limitation of Liability', [
    'To the maximum extent permitted by law, SnowServ\'s total liability under this Agreement '
        'will not exceed the commissions retained from your jobs in the three months before the '
        'claim. SnowServ is not liable for indirect, incidental, or consequential damages.',
  ]),
  _Clause('14. Governing Law & Disputes', [
    'This Agreement is governed by the laws of the State of New York, without regard to its '
        'conflict-of-laws rules. The parties consent to the exclusive jurisdiction of the state '
        'and federal courts located in Westchester County, New York.',
  ]),
  _Clause('15. General', [
    'This Agreement, together with the SnowServ Terms of Service and Privacy Policy, is the '
        'entire agreement regarding your work as a provider. SnowServ may update it with notice '
        'through the app; continued use after an update means you accept the new version. If any '
        'part is unenforceable, the rest remains in effect. You may not assign this Agreement; '
        'SnowServ may.',
  ]),
];

class ProviderAgreementScreen extends StatelessWidget {
  const ProviderAgreementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider Service Agreement')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('SnowServ Provider Service Agreement',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
          const SizedBox(height: 4),
          Text('Version $kProviderAgreementVersion',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 14),
          const Text(_intro, style: TextStyle(fontSize: 14, height: 1.45)),
          const SizedBox(height: 8),
          const Divider(height: 28),
          for (final c in _clauses) ...[
            Text(c.heading,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: SnowServColors.navy)),
            const SizedBox(height: 6),
            for (final line in c.body)
              Padding(
                padding: EdgeInsets.only(left: line.startsWith('•') ? 8 : 0, bottom: 8),
                child: Text(line, style: const TextStyle(fontSize: 14, height: 1.45)),
              ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SnowServColors.frost,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SnowServColors.glacier),
            ),
            child: const Text(
              'By typing your full legal name and tapping "Sign & Agree" on the '
              'registration screen, you acknowledge you have read, understood, and agree to '
              'be bound by this Agreement, and that your typed name is your electronic '
              'signature with the same effect as a handwritten one.',
              style: TextStyle(fontSize: 13, height: 1.4, color: SnowServColors.navy),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
