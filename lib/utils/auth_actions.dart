import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signs the user out without ever leaving them stuck on the screen.
///
/// The default `signOut()` is a GLOBAL sign-out: it calls the server to revoke
/// the refresh token. When that token is already stale — an expired session, a
/// server hiccup, no signal — the call THROWS, the local session is never
/// cleared, and AuthGate has no reason to rebuild. Several screens fired it as
/// `onPressed: () => auth.signOut()` with no await and no catch, so the throw
/// went nowhere and the button simply appeared dead. That is exactly what Vince
/// hit on the "application under review" screen.
///
/// Falling back to a LOCAL sign-out clears the session on the device regardless
/// of what the server says, which is what the user actually asked for when they
/// tapped Log Out.
Future<void> signOutSafely(BuildContext context) async {
  final auth = Supabase.instance.client.auth;
  try {
    await auth.signOut();
  } catch (_) {
    try {
      await auth.signOut(scope: SignOutScope.local);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not log out: $e')),
        );
      }
    }
  }
}
