import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/customer/customer_home.dart';
import 'screens/provider/provider_home.dart';
import 'screens/provider/provider_registration_screen.dart';
import 'theme.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  Stripe.publishableKey = 'pk_test_51TlZBgBYwOCAVVcUcMmYaVCyiv7YF8unZA7afdyHkAFauYaxiLVwU8Z4fhWScwRgm7cAmC5H6kGYfHT03tRuyvbX00MR63QKKG';
  await Stripe.instance.applySettings();

  await Supabase.initialize(
    url: 'https://swttuujhcgpcsrxgupzv.supabase.co',
    publishableKey: 'sb_publishable_SnyCvdfwgHOQe-NB0D8Ipw_DUI9uWRe',
  );

  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnowServ',
      debugShowCheckedModeBanner: false,
      theme: buildSnowServTheme(),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = snapshot.data?.session;
        if (session != null) return const RoleRouter();
        return const AuthScreen();
      },
    );
  }
}

class RoleRouter extends StatefulWidget {
  const RoleRouter({super.key});

  @override
  State<RoleRouter> createState() => _RoleRouterState();
}

class _RoleRouterState extends State<RoleRouter> {
  String? role;
  String? registrationStatus;

  @override
  void initState() {
    super.initState();
    loadRole();
    initNotifications();
  }

  Future<void> initNotifications() async {
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      debugPrint('FCM auth status: ${settings.authorizationStatus}');
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        // iOS requires APNs token before FCM token — retry up to 15 times
        String? apnsToken;
        for (int i = 0; i < 15; i++) {
          apnsToken = await messaging.getAPNSToken();
          if (apnsToken != null) break;
          await Future.delayed(const Duration(seconds: 2));
        }
        if (apnsToken != null) {
          final token = await messaging.getToken();
          if (token != null) {
            debugPrint('FCM token obtained: $token');
            try {
              await supabase.from('profiles').update({'fcm_token': token}).eq(
                  'id', supabase.auth.currentUser!.id);
              debugPrint('FCM token saved successfully');
            } catch (saveErr) {
              debugPrint('FCM token save error: $saveErr');
            }
          }
        } else {
          debugPrint('APNs token not available');
        }
        messaging.onTokenRefresh.listen((newToken) async {
          await supabase.from('profiles').update({'fcm_token': newToken}).eq(
              'id', supabase.auth.currentUser!.id);
        });
      }
    } catch (e) {
      debugPrint('FCM init error: $e');
    }

    FirebaseMessaging.onMessage.listen((message) {
      if (!mounted) return;
      final notification = message.notification;
      if (notification != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${notification.title}: ${notification.body}'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    });
  }

  Future<void> loadRole() async {
    try {
      final data = await supabase
          .from('profiles')
          .select('role')
          .eq('id', supabase.auth.currentUser!.id)
          .maybeSingle();
      if (data == null) return;
      final fetchedRole = data['role'] as String?;

      if (fetchedRole == 'provider') {
        final providerData = await supabase
            .from('providers')
            .select('registration_status')
            .eq('user_id', supabase.auth.currentUser!.id)
            .maybeSingle();
        if (mounted) {
          setState(() {
            role = fetchedRole;
            registrationStatus = providerData?['registration_status'] ?? 'incomplete';
          });
        }
      } else {
        if (mounted) setState(() => role = fetchedRole);
      }
    } catch (e) {
      if (mounted) setState(() => role = 'unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (role == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (role == 'customer') return const CustomerHome();
    if (role == 'provider') {
      if (registrationStatus == 'approved') return const ProviderHome();
      if (registrationStatus == 'pending_review') return const ProviderPendingScreen();
      if (registrationStatus == 'rejected') return const ProviderPendingScreen(isRejected: true);
      return const ProviderRegistrationScreen();
    }
    return const AuthScreen();
  }
}
