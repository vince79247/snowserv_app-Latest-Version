import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart' show TextInput;
import 'dart:math';
import '../../theme.dart';
import '../../utils/legal.dart';
import '../faq_screen.dart';
import '../quote_screen.dart';
import '../provider_interest_screen.dart';
import 'reset_password_screen.dart';

final supabase = Supabase.instance.client;

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  bool isLogin = true;
  // NULL until the person actually picks. Signing up is the ONE irreversible
  // fork in this app — a customer account can't order work done for them and a
  // provider account can't take jobs — and a pre-selected default meant the
  // whole choice could be skipped by simply not noticing it. A contractor did
  // exactly that (Jose, 2026-08-04): he signed up, landed on the customer side,
  // and neither of us knew until his account sat at zero orders.
  String? selectedRole;
  // Opt-in for non-operational email only (season opening, new service areas,
  // re-engagement). Defaults false — the Terms promise marketing is opt-in.
  bool marketingOptIn = false;
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

  // Material (not a plain Container) so the tap ripple actually paints — a
  // coloured box in between swallows it, which is what made the provider
  // registration cards feel dead under the finger.
  Widget _roleCard({
    required String value,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = selectedRole == value;
    return Material(
      color: selected ? SnowServColors.navy.withValues(alpha: 0.06) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => selectedRole = value),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? SnowServColors.navy : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? SnowServColors.navy : Colors.grey.shade600),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.w600,
                          color: SnowServColors.navy,
                        )),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade700)),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected ? SnowServColors.navy : Colors.grey.shade400,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> handleAuth() async {
    if (!isLogin) {
      if (selectedRole == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please choose whether you are hiring someone or '
                'looking to work.'),
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
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
          // No role-match guard at login anymore: login doesn't ask for a role,
          // so there's nothing to mismatch. RoleRouter reads the profile after
          // sign-in and routes to customer home, provider home, or the Admin
          // Panel. (The old guard here signed admins out because there was no
          // Admin tab for the picked role to match.)
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
            // Non-null by the guard at the top of this method. Asserted rather
            // than defaulted on purpose: silently falling back to 'customer' is
            // the exact failure we are closing.
            'role': selectedRole!,
            'full_name': nameController.text.trim(),
            'phone': phoneController.text.trim(),
            // Read by handle_new_user, which treats anything but the string
            // 'true' as a no — a build that omits this can't imply consent.
            'marketing_opt_in': marketingOptIn.toString(),
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

                      // Role is chosen at SIGN-UP only. At LOGIN we don't ask
                      // "are you a customer or provider" — you enter email +
                      // password and RoleRouter routes you by your account
                      // (customer home, provider home, or Admin Panel). This is
                      // also what lets an ADMIN log in: there was never an Admin
                      // tab, and the old guard demanded the picked tab match.
                      if (!isLogin) ...[
                        // Worded as what you WANT, not as what we call you.
                        // "Customer" and "Provider" are our words; somebody
                        // looking for plowing work does not necessarily read
                        // "Provider" as themselves, and the old segmented
                        // control started on Customer so getting it wrong took
                        // no action at all.
                        const Text(
                          'Which one are you? *',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: SnowServColors.navy),
                        ),
                        const SizedBox(height: 8),
                        _roleCard(
                          value: 'customer',
                          icon: Icons.home_outlined,
                          title: 'I need snow removed',
                          subtitle: 'Order plowing or shoveling at your home',
                        ),
                        const SizedBox(height: 8),
                        _roleCard(
                          value: 'provider',
                          icon: Icons.ac_unit,
                          title: 'I want to plow and get paid',
                          subtitle: 'Take jobs near you and keep 75%',
                        ),
                        const SizedBox(height: 20),
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
                        const SizedBox(height: 6),
                        // Consent for NON-operational email only. Ships UNCHECKED
                        // and sits BELOW the Sign Up button on purpose: opt-in has
                        // to be a deliberate act, not something that happens to
                        // someone skimming a form. Job/receipt/account email is
                        // unaffected and needs no checkbox — the Terms cover it.
                        InkWell(
                          onTap: () => setState(() => marketingOptIn = !marketingOptIn),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Checkbox(
                                    value: marketingOptIn,
                                    onChanged: (v) =>
                                        setState(() => marketingOptIn = v ?? false),
                                    side: const BorderSide(color: Colors.white54),
                                    checkColor: SnowServColors.navy,
                                    fillColor: WidgetStateProperty.resolveWith((s) =>
                                        s.contains(WidgetState.selected)
                                            ? Colors.white
                                            : Colors.transparent),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'Email me when we open for the season or expand to new '
                                    'areas. (Optional — you\'ll always get order updates.)',
                                    style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.35),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
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
                const SizedBox(height: 8),
                // Supply-side entry point. Sits next to the customer quote
                // because pre-season the scarcer side is PROVIDERS — a storm
                // with no one to dispatch to strands every order, and you can't
                // recruit mid-storm.
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ProviderInterestScreen()),
                  ),
                  icon: const Icon(Icons.ac_unit, size: 18, color: Colors.white),
                  label: const Text('Plow with us — earn 75% per job',
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
