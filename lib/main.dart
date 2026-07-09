import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/customer/customer_home.dart';
import 'screens/provider/provider_home.dart';
import 'screens/provider/provider_registration_screen.dart';
import 'theme.dart';
import 'config/app_config.dart';
import 'utils/web_layout.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase/FCM is mobile-only for now: initializeApp() without explicit
  // FirebaseOptions THROWS on web (white-screens the app before anything
  // renders). Web push would need firebase config for web + a VAPID key +
  // service worker — a separate feature; web users can order without push.
  if (!kIsWeb) {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  // Payments run through Stripe Checkout (hosted page) now — no client-side
  // Stripe SDK to initialize. The publishable key lives server-side / on the
  // Checkout Session, and Checkout works on iOS, Android AND web.
  await Supabase.initialize(
    url: 'https://swttuujhcgpcsrxgupzv.supabase.co',
    publishableKey: 'sb_publishable_SnyCvdfwgHOQe-NB0D8Ipw_DUI9uWRe',
  );

  // Load admin-editable business config (e.g. commission %). Non-fatal.
  await AppConfig.load();

  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

// Web-only scroll behavior: lets every pointer type (including a plain mouse
// click-drag) scroll, so desktop users aren't stuck when wheel events miss.
class _WebScrollBehavior extends MaterialScrollBehavior {
  const _WebScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      };
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SnowServ',
      debugShowCheckedModeBanner: false,
      theme: buildSnowServTheme(),
      home: const AuthGate(),
      // WEB: the UI is phone-first, so on a wide desktop browser cap it at a
      // phone-ish column centered on a frost backdrop instead of stretching
      // edge-to-edge. Mobile builds (and narrow browser windows) are untouched
      // because the constraint only bites when the window is wider than 520.
      builder: (context, child) {
        if (!kIsWeb || child == null) return child ?? const SizedBox.shrink();
        // The column width is a notifier so the admin panel can widen to full
        // width and restore on exit (see web_layout.dart / openAdminPanel).
        return ValueListenableBuilder<double>(
          valueListenable: webContentMaxWidth,
          // Desktop-web scrolling is finicky: wheel/trackpad only works with the
          // cursor over a scrollable. Allow mouse DRAG scrolling too (like
          // swiping on a phone) so the page always moves. Passed as the cached
          // child so it isn't rebuilt when only the width changes.
          child: ScrollConfiguration(
            behavior: const _WebScrollBehavior(),
            child: child,
          ),
          builder: (context, maxWidth, scrollChild) => ColoredBox(
            color: SnowServColors.frost,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Material(
                  elevation: 4,
                  shadowColor: SnowServColors.glacier,
                  clipBehavior: Clip.antiAlias,
                  child: scrollChild,
                ),
              ),
            ),
          ),
        );
      },
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
    // No Firebase app on web (see main) — every FirebaseMessaging call would
    // throw. Web push is a later feature.
    if (kIsWeb) return;
    try {
      final messaging = FirebaseMessaging.instance;
      // Persist any future token (rotation, or a late first fetch) unconditionally
      // and FIRST, so a device can't end up with a stale/missing saved token even
      // if the initial fetch below is slow. (This fragility is exactly what made
      // push silently "stop working" after testing across sims/devices.)
      messaging.onTokenRefresh.listen(_saveFcmToken);

      final settings = await messaging.requestPermission();
      debugPrint('FCM auth status: ${settings.authorizationStatus}');
      // iOS hides notification banners while the app is in the foreground by
      // default. A provider sitting on the "Waiting for jobs" screen must still
      // see the "New Job Offer!" alert, so opt into foreground presentation.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true, badge: true, sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        await _fetchAndSaveFcmToken(messaging);
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

  // Gets and saves the FCM token, retrying so a slow cold-launch registration
  // doesn't leave the device without a saved token. iOS needs the APNs token
  // before FCM can mint one; Android has no APNs step so it skips that wait.
  Future<void> _fetchAndSaveFcmToken(FirebaseMessaging messaging) async {
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    for (int i = 0; i < 20; i++) {
      try {
        if (isIOS && await messaging.getAPNSToken() == null) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        final token = await messaging.getToken();
        if (token != null) {
          await _saveFcmToken(token);
          return;
        }
      } catch (e) {
        debugPrint('FCM token attempt $i failed: $e');
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    debugPrint('FCM token not obtained after retries');
  }

  Future<void> _saveFcmToken(String token) async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    try {
      await supabase.from('profiles').update({'fcm_token': token}).eq('id', userId);
      debugPrint('FCM token saved');
    } catch (e) {
      debugPrint('FCM token save error: $e');
    }
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
