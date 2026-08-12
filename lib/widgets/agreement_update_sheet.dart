import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';
import '../screens/provider/provider_agreement_screen.dart';

/// Asks a provider to accept the current Provider Service Agreement when the
/// version they signed is out of date — or when they never signed one at all.
///
/// WHY IT EXISTS: the agreement was signed at REGISTRATION ONLY and nothing ever
/// re-checked it, so §3A (added in v1.3) bound nobody already on the platform.
/// Worse, two of the four approved providers had NO version on file at all —
/// they predate the signing step entirely. "We'll ask them in October" was the
/// plan, and this is what makes it happen by itself instead of depending on
/// someone remembering to chase four people individually. That is exactly how
/// those two ended up unsigned the first time.
///
/// FRAMING (Vince's call, and it is the right one): "We've updated our terms" —
/// the familiar, non-alarming pattern everyone recognizes from every app they
/// use. It is honest, and it does not imply the provider did something wrong.
/// The copy switches to a first-time framing for anyone with nothing on file,
/// because telling them we "updated" an agreement they never signed would be a
/// small lie in the first sentence they read.
///
/// Shown at GOING ONLINE, not app open: that is a deliberate "I'm starting work"
/// moment, it happens before any job exists, and it means nobody is handed a
/// contract in the middle of a storm.
///
/// Returns true only if they signed.
Future<bool> showAgreementUpdate(
  BuildContext context, {
  required String providerId,
  required String? signedVersion,
  String? providerName,
}) async {
  final firstTime = signedVersion == null || signedVersion.trim().isEmpty;
  final nameCtl = TextEditingController(text: providerName ?? '');
  var agreed = false;
  var saving = false;

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.assignment_outlined,
                      color: SnowServColors.iceBlue, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      firstTime
                          ? 'One thing to sign before you start'
                          : "We've updated our Provider Agreement",
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: SnowServColors.navy),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                firstTime
                    ? 'You signed up before we had an agreement in place, so there '
                        'is nothing on file for you yet. It takes a minute.'
                    : 'Nothing about your pay, your commission, or how jobs are '
                        'assigned has changed.',
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: SnowServColors.surfaceSoft,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SnowServColors.hairline),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("What's new",
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: SnowServColors.navy)),
                    SizedBox(height: 8),
                    Text(
                      '• Your account is yours alone. The person who registers is '
                      'the person who does the work — no sharing or handing your '
                      'login to someone else.\n\n'
                      '• Helpers are fine. Bring your crew, your family, whoever '
                      'you like. You stay responsible for the job and for anyone '
                      'you bring. What is not allowed is sending someone in your '
                      'place.',
                      style: TextStyle(fontSize: 13.5, height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              GestureDetector(
                onTap: () => Navigator.push(
                    ctx,
                    MaterialPageRoute(
                        builder: (_) => const ProviderAgreementScreen())),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                  decoration: BoxDecoration(
                    color: SnowServColors.iceBlue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: SnowServColors.iceBlue.withValues(alpha: 0.25)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.menu_book_outlined,
                          color: SnowServColors.iceBlue, size: 20),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text('Read the full agreement',
                            style: TextStyle(
                                color: SnowServColors.iceBlue,
                                fontWeight: FontWeight.w600)),
                      ),
                      Icon(Icons.chevron_right,
                          color: SnowServColors.iceBlue, size: 20),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Type your full legal name to sign',
                  prefixIcon: Icon(Icons.draw_outlined),
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setSheet(() {}),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: agreed,
                onChanged: (v) => setSheet(() => agreed = v ?? false),
                activeColor: SnowServColors.iceBlue,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'I have read and agree to the Provider Service Agreement, and '
                  'my typed name above is my electronic signature.',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (!agreed ||
                          nameCtl.text.trim().length < 3 ||
                          saving)
                      ? null
                      : () async {
                          setSheet(() => saving = true);
                          try {
                            await Supabase.instance.client
                                .from('providers')
                                .update({
                              'service_agreement_signed_at':
                                  DateTime.now().toUtc().toIso8601String(),
                              'service_agreement_name': nameCtl.text.trim(),
                              'service_agreement_version':
                                  kProviderAgreementVersion,
                            }).eq('id', providerId);
                            if (ctx.mounted) Navigator.pop(ctx, true);
                          } catch (e) {
                            setSheet(() => saving = false);
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                                  content: Text("Couldn't save your "
                                      'signature: $e')));
                            }
                          }
                        },
                  child: saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Agree and continue'),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: TextButton(
                  onPressed: saving ? null : () => Navigator.pop(ctx, false),
                  // Backing out is allowed — it just leaves them offline. A
                  // contract nobody can decline is not consent.
                  child: const Text('Not now',
                      style: TextStyle(color: SnowServColors.inkSoft)),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  nameCtl.dispose();
  return result == true;
}
