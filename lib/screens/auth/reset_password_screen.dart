import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme.dart';

// Forgot-password via an in-app 6-digit CODE (OtpType.recovery) — no reset link,
// no hosted web page, no deep link. Works identically on iOS, Android and web.
//
// Flow: send a recovery code to the email → user enters the code + a new password
// → verifyOTP(recovery) establishes a short-lived recovery session → updateUser
// sets the new password → we sign back out so they log in fresh with it.
//
// REQUIRES (build-5 cutover): the Supabase "Reset Password" email template must
// include the {{ .Token }} variable so the email actually shows the 6-digit code
// (the default template only contains a magic link). See PRELAUNCH.md.

final _supabase = Supabase.instance.client;

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, this.initialEmail = ''});
  final String initialEmail;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  late final TextEditingController _emailController =
      TextEditingController(text: widget.initialEmail);
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _codeSent = false;
  bool _sending = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // If we arrived with a valid-looking email, send the code immediately so the
    // user lands on the code-entry step.
    if (_looksLikeEmail(_emailController.text)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendCode());
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  bool _looksLikeEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : null,
      duration: const Duration(seconds: 4),
    ));
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!_looksLikeEmail(email)) {
      _snack('Enter a valid email address.');
      return;
    }
    setState(() => _sending = true);
    try {
      await _supabase.auth.resetPasswordForEmail(email);
      if (!mounted) return;
      setState(() => _codeSent = true);
      _snack('We emailed a 6-digit code to $email.');
    } catch (e) {
      // Supabase intentionally does NOT reveal whether an email exists, so a
      // send rarely errors; a thrown error here is usually rate-limiting.
      _snack('Could not send a code right now. Wait a minute and try again.', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    final pass = _passwordController.text;
    final confirm = _confirmController.text;

    if (code.length < 6) {
      _snack('Enter the 6-digit code from your email.');
      return;
    }
    if (pass.length < 8) {
      _snack('Your new password must be at least 8 characters.');
      return;
    }
    if (pass != confirm) {
      _snack('The two passwords do not match.');
      return;
    }

    setState(() => _submitting = true);
    try {
      // 1) Exchange the code for a short-lived recovery session.
      await _supabase.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.recovery,
      );
      // 2) Set the new password on that session.
      await _supabase.auth.updateUser(UserAttributes(password: pass));
      // 3) Sign back out so they log in cleanly with the new password. (This
      //    happens under the pushed screen; we then pop back to the login form.)
      await _supabase.auth.signOut();

      if (!mounted) return;
      Navigator.of(context).pop();
      _snack('Password updated. Please log in with your new password.');
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('expired') || msg.contains('invalid') || msg.contains('token')) {
        _snack('That code is wrong or expired. Tap "Resend code" and try again.', error: true);
      } else if (msg.contains('should be different') || msg.contains('same')) {
        _snack('Choose a password different from your old one.', error: true);
      } else {
        _snack('Could not update your password. Please try again.', error: true);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reset password'),
        backgroundColor: SnowServColors.navy,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text(
                _codeSent
                    ? 'Enter the 6-digit code we emailed you, then choose a new password.'
                    : 'Enter your email and we\'ll send you a 6-digit code.',
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(height: 20),

              TextField(
                controller: _emailController,
                enabled: !_codeSent,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 12),

              if (_codeSent) ...[
                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '6-digit code',
                    prefixIcon: Icon(Icons.pin_outlined),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New password',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Update password'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _sending ? null : _sendCode,
                  child: Text(_sending ? 'Sending…' : 'Resend code'),
                ),
              ] else ...[
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _sending ? null : _sendCode,
                  child: _sending
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Send code'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
