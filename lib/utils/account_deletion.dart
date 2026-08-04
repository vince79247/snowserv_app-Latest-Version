import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// In-app account deletion. REQUIRED by App Store Guideline 5.1.1(v): any app that
// lets a user create an account must let them delete it from inside the app.
// Shared by the customer and provider account menus so both roles get an
// identical, discoverable path (Apple also expects it not to be buried).
//
// The heavy lifting is server-side in the `delete-account` edge function: it
// scrubs the PII, purges provider documents from storage, detaches the card from
// Stripe, and deletes the auth user. Job rows are deliberately KEPT (tax/payout
// records) with the person anonymised on them.

final _supabase = Supabase.instance.client;

/// Account-menu row. Pops the containing sheet, then runs the confirm + delete
/// flow. Styled destructively (red) and placed with Log Out.
ListTile deleteAccountTile(BuildContext context) => ListTile(
      leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
      title: const Text('Delete Account', style: TextStyle(color: Colors.red)),
      onTap: () {
        Navigator.pop(context);
        confirmAndDeleteAccount(context);
      },
    );

Future<void> confirmAndDeleteAccount(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete your account?'),
      content: const SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This is permanent. You will be signed out and will not be able '
                'to log in again with this account.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 12),
              Text(
                'We permanently remove your personal details — your name, email, '
                'phone, saved card, and (for providers) your bank, tax, license '
                'and insurance information.',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                'Records of past jobs are kept for tax and payment purposes, but '
                'they are no longer linked to you.',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 8),
              Text(
                'If you are a provider and still have earnings owed to you, contact '
                'support@snowserv.app to be paid before deleting.',
                style: TextStyle(fontSize: 13, color: Colors.red),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Delete my account'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  // Block the UI while the server does the deletion — this must not be
  // interrupted halfway.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(child: Text('Deleting your account…')),
        ],
      ),
    ),
  );

  try {
    final res = await _supabase.functions
        .invoke('delete-account')
        .timeout(const Duration(seconds: 30));
    final err = res.data is Map ? res.data['error'] : null;
    if (err != null) throw err;

    final owed = (res.data is Map ? res.data['pending_earnings'] : null) ?? 0;

    // Session is dead server-side; clear it locally so AuthGate routes to login.
    await _supabase.auth.signOut();

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close the progress dialog
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          (owed is num && owed > 0)
              ? 'Account deleted. You had \$${owed.toStringAsFixed(2)} in unpaid '
                  'earnings — contact support@snowserv.app to be paid.'
              : 'Your account has been deleted.',
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close the progress dialog
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not delete your account: $e'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 8),
      ),
    );
  }
}
