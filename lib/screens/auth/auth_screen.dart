import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart' show TextInput;
import 'dart:math';
import '../../theme.dart';
import '../../utils/legal.dart';
import '../faq_screen.dart';
import '../quote_screen.dart';
import 'reset_password_screen.dart';

final supabase = Supabase.instance.client;

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  bool isLogin = true;
  String selectedRole = 'customer';
  bool loading = false;

  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final nameController = TextEditingController();
  final phoneController = TextEditingController();

  late AnimationController _snowController;
  late List<_Snowflake> _flakes;

  @override
  void initState() {
    super.initState();
    final rng = Random();
    _snowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _flakes = List.generate(40, (_) => _Snowflake(
      x: rng.nextDouble(),
      size: 1.5 + rng.nextDouble() * 3.0,
      phase: rng.nextDouble(),
      drift: 8.0 + rng.nextDouble() * 18.0,
      speed: 0.4 + rng.nextDouble() * 0.7,
    ));
  }

  @override
  void dispose() {
    _snowController.dispose();
    emailController.dispose();
    passwordController.dispose();
    nameController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  Future<void> handleAuth() async {
    if (!isLogin) {
      if (nameController.text.trim().isEmpty ||
          phoneController.text.trim().isEmpty ||
          emailController.text.trim().isEmpty ||
          passwordController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All fields are required.')),
        );
        return;
      }
      if (passwordController.text.trim().length < 6) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password must be at least 6 characters.')),
        );
        return;
      }
    } else {
      if (emailController.text.trim().isEmpty ||
          passwordController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter your email and password.')),
        );
        return;
      }
    }

    setState(() => loading = true);
    try {
      if (isLogin) {
        final response = await supabase.auth.signInWithPassword(
          email: emailController.text.trim(),
          password: passwordController.text.trim(),
        );
        if (response.user != null) {
          // Credentials accepted — let iOS/iCloud Keychain offer to save them so
          // Face ID fills the password next time. Safe even if the role check
          // below signs them out (the password is still valid for that account).
          TextInput.finishAutofillContext();
          final profile = await supabase
              .from('profiles')
              .select('role')
              .eq('id', response.user!.id)
              .maybeSingle();
          if (profile == null) {
            // Logged in, but no profile row (an older interrupted signup).
            // Don't leave them stuck — sign out with a clear message.
            await supabase.auth.signOut();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text("We couldn't finish setting up this account. "
                    'Please sign up again or contact support@snowserv.app.'),
                duration: Duration(seconds: 6),
              ));
              setState(() => loading = false);
            }
            return;
          }
          if (profile['role'] != selectedRole && mounted) {
            await supabase.auth.signOut();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'This account is registered as a ${profile['role']}. Please select ${profile['role']} and try again.',
                ),
                duration: const Duration(seconds: 5),
              ),
            );
            setState(() => loading = false);
            return;
          }
        }
      } else {
        // Name/phone/role ride along as user metadata. The profiles/users/
        // providers rows are then created SERVER-SIDE by the on_auth_user_created
        // trigger (SECURITY DEFINER) — atomically, and regardless of the signup's
        // no-session-yet timing. The app no longer inserts them client-side: that
        // ran as the anon role in a swallowed try/catch, so any failure silently
        // orphaned the account (signup "succeeded" but login could never find a
        // profile). REQUIRES the trigger to be live — see PRELAUNCH build-5 cutover.
        final response = await supabase.auth.signUp(
          email: emailController.text.trim(),
          password: passwordController.text.trim(),
          data: {
            'role': selectedRole,
            'full_name': nameController.text.trim(),
            'phone': phoneController.text.trim(),
          },
        );
        if (response.user != null && mounted) {
          TextInput.finishAutofillContext(); // let iOS save the new credentials
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created! Check your email to confirm, then log in.'),
              duration: Duration(seconds: 6),
            ),
          );
          setState(() => isLogin = true);
        }
      }
    } catch (e) {
      final message = e.toString();
      String userMessage;
      if (message.contains('duplicate') || message.contains('already')) {
        userMessage = 'An account with this email already exists. Please log in.';
        setState(() => isLogin = true);
      } else if (message.contains('Email not confirmed')) {
        userMessage = 'Please confirm your email before logging in. Check your inbox.';
      } else if (message.contains('Invalid login')) {
        userMessage = 'Incorrect email or password.';
      } else if (message.contains('Password') || message.contains('at least 6')) {
        userMessage = 'Password must be at least 6 characters.';
      } else {
        userMessage = 'Something went wrong. Please try again.';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userMessage), duration: const Duration(seconds: 4)),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void handleForgotPassword() {
    // Opens the in-app code-based reset flow (send 6-digit code → verify →
    // set new password). The screen owns sending + entry; pre-fill the email
    // if one's already typed.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ResetPasswordScreen(initialEmail: emailController.text.trim()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [SnowServColors.navy, SnowServColors.navyMid],
              ),
            ),
          ),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _snowController,
              builder: (_, __) => CustomPaint(
                painter: _SnowfallPainter(_snowController.value, _flakes),
              ),
            ),
          ),
          SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),

                const Text(
                  '❄',
                  style: TextStyle(fontSize: 56, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'SnowServ',
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 2,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  'On-demand snow removal',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.blue[200],
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 40),

                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  // AutofillGroup is REQUIRED for iOS/Android to offer to save
                  // the credentials (and for Face-ID fill next time). Without it
                  // the autofillHints below do nothing on submit.
                  child: AutofillGroup(
                    child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        isLogin ? 'Welcome back' : 'Create your account',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: SnowServColors.navy,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),

                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'customer',
                            label: Text('Customer'),
                          ),
                          ButtonSegment(
                            value: 'provider',
                            label: Text('Provider'),
                          ),
                        ],
                        selected: {selectedRole},
                        onSelectionChanged: (val) =>
                            setState(() => selectedRole = val.first),
                      ),
                      const SizedBox(height: 20),

                      if (!isLogin) ...[
                        const Text(
                          '* All fields are required',
                          style: TextStyle(fontSize: 12, color: Colors.red),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: nameController,
                          decoration: const InputDecoration(
                            labelText: 'Full Name *',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: phoneController,
                          decoration: const InputDecoration(
                            labelText: 'Phone Number *',
                            prefixIcon: Icon(Icons.phone_outlined),
                          ),
                          keyboardType: TextInputType.phone,
                        ),
                        const SizedBox(height: 12),
                      ],

                      TextField(
                        controller: emailController,
                        decoration: InputDecoration(
                          labelText: isLogin ? 'Email' : 'Email *',
                          prefixIcon: const Icon(Icons.email_outlined),
                        ),
                        autofillHints: const [AutofillHints.username, AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: passwordController,
                        decoration: InputDecoration(
                          labelText: isLogin ? 'Password' : 'Password *',
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
                        autofillHints: const [AutofillHints.password],
                        obscureText: true,
                      ),
                      const SizedBox(height: 24),

                      ElevatedButton(
                        onPressed: loading ? null : handleAuth,
                        child: loading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(isLogin ? 'Log In' : 'Sign Up'),
                      ),

                      if (!isLogin) ...[
                        const SizedBox(height: 12),
                        const LegalConsentText(),
                      ],

                      const SizedBox(height: 8),

                      TextButton(
                        onPressed: () {
                          setState(() {
                            isLogin = !isLogin;
                            nameController.clear();
                            phoneController.clear();
                            emailController.clear();
                            passwordController.clear();
                          });
                        },
                        child: Text(
                          isLogin
                              ? "Don't have an account? Sign Up"
                              : 'Already have an account? Log In',
                          style: const TextStyle(color: SnowServColors.iceBlue),
                        ),
                      ),

                      if (isLogin) ...[
                        TextButton(
                          onPressed: handleForgotPassword,
                          child: const Text(
                            'Forgot Password?',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      ],
                    ],
                  )),
                ),

                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final wantsSignup = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(builder: (_) => const QuoteScreen()),
                    );
                    // "Sign up to book" on the quote screen → switch to signup.
                    if (wantsSignup == true && mounted) {
                      setState(() => isLogin = false);
                    }
                  },
                  icon: const Icon(Icons.calculate_outlined, size: 18, color: Colors.white),
                  label: const Text('Get an instant quote — no account needed',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white54)),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const FaqScreen()),
                  ),
                  icon: const Icon(Icons.help_outline, size: 16, color: Colors.white70),
                  label: const Text('Have questions? Read our FAQ',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => openLegalUrl(privacyPolicyUrl),
                      child: const Text('Privacy Policy', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                    const Text('·', style: TextStyle(color: Colors.white30)),
                    TextButton(
                      onPressed: () => openLegalUrl(termsOfServiceUrl),
                      child: const Text('Terms of Service', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                  ],
                ),
                const Text(
                  '❄   ❄   ❄',
                  style: TextStyle(color: Colors.white30, fontSize: 18),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
          ],
        ),
    );
  }
}

class _Snowflake {
  final double x;
  final double size;
  final double phase;
  final double drift;
  final double speed;
  const _Snowflake({required this.x, required this.size, required this.phase, required this.drift, required this.speed});
}

class _SnowfallPainter extends CustomPainter {
  final double progress;
  final List<_Snowflake> flakes;
  _SnowfallPainter(this.progress, this.flakes);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withOpacity(0.55);
    for (final flake in flakes) {
      final t = (progress * flake.speed + flake.phase) % 1.0;
      final y = t * (size.height + 20) - 10;
      final x = flake.x * size.width +
          sin(progress * 2 * pi * flake.speed * 2 + flake.phase * 10) * flake.drift;
      canvas.drawCircle(Offset(x, y), flake.size, paint);
    }
  }

  @override
  bool shouldRepaint(_SnowfallPainter old) => true;
}
