import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math';
import '../../theme.dart';
import '../admin/admin_screen.dart';

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
          final profile = await supabase
              .from('profiles')
              .select('role')
              .eq('id', response.user!.id)
              .single();
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
        final response = await supabase.auth.signUp(
          email: emailController.text.trim(),
          password: passwordController.text.trim(),
        );
        if (response.user != null) {
          try {
            await supabase.from('profiles').insert({
              'id': response.user!.id,
              'role': selectedRole,
              'full_name': nameController.text.trim(),
              'phone': phoneController.text.trim(),
            });
            await supabase.from('users').insert({
              'id': response.user!.id,
              'name': nameController.text.trim(),
              'email': emailController.text.trim(),
              'phone': phoneController.text.trim(),
              'role': selectedRole,
            });
            if (selectedRole == 'provider') {
              await supabase.from('providers').insert({
                'user_id': response.user!.id,
                'is_online': false,
              });
            }
          } catch (e) {
            debugPrint('Profile setup error: $e');
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Account created! Check your email to confirm, then log in.'),
                duration: Duration(seconds: 6),
              ),
            );
            setState(() => isLogin = true);
          }
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

  Future<void> handleForgotPassword() async {
    final email = emailController.text.trim();
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email first, then tap Forgot Password.')),
      );
      return;
    }
    await supabase.auth.resetPasswordForEmail(email);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password reset email sent. Check your inbox.')),
      );
    }
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
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: passwordController,
                        decoration: InputDecoration(
                          labelText: isLogin ? 'Password' : 'Password *',
                          prefixIcon: const Icon(Icons.lock_outline),
                        ),
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
                        const Divider(),
                        TextButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AdminLoginScreen()),
                          ),
                          icon: const Icon(Icons.admin_panel_settings,
                              size: 16, color: Colors.grey),
                          label: const Text(
                            'Admin Access',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse('https://docs.google.com/document/d/e/2PACX-1vTs3QKh1Sh_d9RfCX4w1lgWhugWIld3VGiLSJnFHE5-Yd-qIj9v5rrrI8FMYTtYa85aY2aP2-aKFHRi/pub'),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: const Text('Privacy Policy', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                    const Text('·', style: TextStyle(color: Colors.white30)),
                    TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse('https://docs.google.com/document/d/e/2PACX-1vTcXcBxj_5lSgLWeWzPpPFWxSmA1BOjMgNs1fdFg1NFqZnIEWtluIwCyXbJLpnttfc0vD2Mts6IZcxb/pub'),
                        mode: LaunchMode.externalApplication,
                      ),
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
