import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/customer/customer_home.dart';
import 'screens/provider/provider_home.dart';
import 'theme.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await Supabase.initialize(
    url: 'https://swttuujhcgpcsrxgupzv.supabase.co',
    anonKey: 'sb_publishable_SnyCvdfwgHOQe-NB0D8Ipw_DUI9uWRe',
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

  @override
  void initState() {
    super.initState();
    loadRole();
    initNotifications();
  }

  Future<void> initNotifications() async {
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      final token = await messaging.getToken();
      if (token != null) {
        await supabase.from('profiles').update({'fcm_token': token}).eq(
            'id', supabase.auth.currentUser!.id);
      }
      messaging.onTokenRefresh.listen((newToken) async {
        await supabase.from('profiles').update({'fcm_token': newToken}).eq(
            'id', supabase.auth.currentUser!.id);
      });
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
          .single();
      if (mounted) setState(() => role = data['role']);
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
    if (role == 'provider') return const ProviderHome();
    return const AuthScreen();
  }
}
