import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, PointerSignalEvent, PointerScrollEvent;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'screens/auth/auth_screen.dart';
import 'screens/customer/customer_home.dart';
import 'screens/provider/provider_home.dart';
import 'screens/admin/admin_screen.dart';
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

// Local notifications: Android does NOT display foreground FCM messages the way
// iOS does, so on Android we post a heads-up notification ourselves on this
// high-importance channel — giving a real system banner + sound when the app is
// open, matching iOS (which uses setForegroundNotificationPresentationOptions).
final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();
const AndroidNotificationChannel _kJobChannel = AndroidNotificationChannel(
  'snowserv_jobs',
  'Job Alerts',
  description: 'New job offers and job updates',
  importance: Importance.max,
  playSound: true,
);

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

/// WEB layout frame. On a wide desktop browser the phone-first UI is capped to
/// a phone-width card centered on a frost backdrop (see web_layout.dart). The
/// scrollable content lives INSIDE that card, so wheel/trackpad events over the
/// frost margins on either side have no scrollable under them — the page won't
/// move ("scroll dead zone"). This frame fixes that: it tracks the current
/// page's outermost scroll position (via ScrollMetricsNotification) and, when a
/// wheel/trackpad scroll lands on the margins, forwards it to that scrollable —
/// so scrolling works anywhere in the window while keeping the centered look.
class _WebFrame extends StatefulWidget {
  const _WebFrame({required this.child});
  final Widget child;
  @override
  State<_WebFrame> createState() => _WebFrameState();
}

class _WebFrameState extends State<_WebFrame> {
  // Key on the visible card, used to tell "over the card" from "over a margin".
  final GlobalKey _cardKey = GlobalKey();
  // The current page's outermost (depth 0) scroll position, captured whenever a
  // page with a scroll view lays out or scrolls.
  ScrollPosition? _pageScroll;

  bool _isInsideCard(Offset globalPos) {
    final box = _cardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final local = box.globalToLocal(globalPos);
    return local.dx >= 0 &&
        local.dx <= box.size.width &&
        local.dy >= 0 &&
        local.dy <= box.size.height;
  }

  void _handleSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final pos = _pageScroll;
    if (pos == null || !pos.hasPixels || !pos.hasContentDimensions) return;
    // Over the card, the Scrollable handles the wheel itself — forwarding here
    // too would double-scroll. Only forward events that land on the margins.
    if (_isInsideCard(event.position)) return;
    final target = (pos.pixels + event.scrollDelta.dy)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    if (target == pos.pixels) return;
    try {
      pos.jumpTo(target);
    } catch (_) {
      // Position was disposed (page changed) — drop it; re-captured on relayout.
      _pageScroll = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        if (n.depth == 0) {
          final s = Scrollable.maybeOf(n.context);
          if (s != null) _pageScroll = s.position;
        }
        return false;
      },
      child: Listener(
        onPointerSignal: _handleSignal,
        // The column width is a notifier so the admin panel can widen to full
        // width and restore on exit (see web_layout.dart / openAdminPanel).
        child: ValueListenableBuilder<double>(
          valueListenable: webContentMaxWidth,
          // Allow mouse DRAG scrolling too (like swiping on a phone). Passed as
          // the cached child so it isn't rebuilt when only the width changes.
          child: ScrollConfiguration(
            behavior: const _WebScrollBehavior(),
            child: widget.child,
          ),
          builder: (context, maxWidth, scrollChild) => ColoredBox(
            color: SnowServColors.frost,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Material(
                  key: _cardKey,
                  elevation: 4,
                  shadowColor: SnowServColors.glacier,
                  clipBehavior: Clip.antiAlias,
                  child: scrollChild,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
        return _WebFrame(child: child);
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
        // Fall back to the session Supabase.initialize() already restored from
        // storage: on a COLD restart (e.g. Android killed the app in the
        // background while the photo picker was open) the stream hasn't emitted
        // yet, so snapshot.data is null — without this fallback the app would
        // wrongly bounce a still-logged-in user to the login screen.
        final session = snapshot.data?.session ?? supabase.auth.currentSession;
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
  // Admin is a first-class login: an is_admin account lands straight on the
  // Admin Panel — it is NOT a customer or provider and never sees those homes.
  bool isAdmin = false;

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

      // Android foreground heads-up: initialize the local-notifications plugin
      // and create the high-importance channel so onMessage can post a real
      // banner + sound while the app is open (iOS handles this natively above).
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _localNotifications.initialize(
          const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        final android = _localNotifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await android?.createNotificationChannel(_kJobChannel);
        await android?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('FCM init error: $e');
    }

    FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      if (notification == null) return;
      if (defaultTargetPlatform == TargetPlatform.android) {
        // Android doesn't auto-present foreground FCM messages — post a
        // heads-up system notification (banner + sound) for iOS parity.
        _localNotifications.show(
          notification.hashCode,
          notification.title,
          notification.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              _kJobChannel.id,
              _kJobChannel.name,
              channelDescription: _kJobChannel.description,
              importance: Importance.max,
              priority: Priority.high,
              playSound: true,
              icon: '@mipmap/ic_launcher',
            ),
          ),
        );
      } else if (mounted) {
        // iOS already shows the system banner via the foreground presentation
        // options set above; keep a lightweight in-app snackbar too.
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
      // A device has ONE FCM token. Claim it for the current user server-side
      // (SECURITY DEFINER RPC): clears the token off any OTHER profile that
      // still holds it — a previous account on this phone — then saves it on
      // ours. Doing the cross-clear client-side doesn't work: RLS (correctly)
      // blocks updating another user's row, which is how an "accepted" push
      // once landed on the wrong provider's phone.
      await supabase.rpc('claim_fcm_token', params: {'p_token': token});
      debugPrint('FCM token claimed');
    } catch (e) {
      debugPrint('FCM token claim error: $e — falling back to own-row save');
      try {
        await supabase.from('profiles').update({'fcm_token': token}).eq('id', userId);
      } catch (e2) {
        debugPrint('FCM token save error: $e2');
      }
    }
  }

  Future<void> loadRole() async {
    try {
      final data = await supabase
          .from('profiles')
          .select('role, is_admin')
          .eq('id', supabase.auth.currentUser!.id)
          .maybeSingle();
      if (data == null) {
        // Session with no profile row (e.g. an interrupted signup). Don't hang
        // on the spinner forever — sign out so AuthGate shows a clean login.
        await supabase.auth.signOut();
        return;
      }
      final fetchedRole = data['role'] as String?;
      final fetchedAdmin = data['is_admin'] == true;

      // The admin panel is a full-width back-office screen; every other screen is
      // the phone-width web column. Set the web column width HERE — this runs in
      // async loadRole (off the build phase, so no "markNeedsBuild during build"
      // and no resize flash) and covers logging STRAIGHT IN as an admin, which
      // RoleRouter renders directly (openAdminPanel's push path is never hit).
      // On mobile the notifier is unused (the _WebFrame only applies on web).
      webContentMaxWidth.value = (fetchedAdmin || fetchedRole == 'admin')
          ? kAdminWebWidth
          : kPhoneWebWidth;

      if (fetchedRole == 'provider') {
        final providerData = await supabase
            .from('providers')
            .select('registration_status')
            .eq('user_id', supabase.auth.currentUser!.id)
            .maybeSingle();
        if (mounted) {
          setState(() {
            role = fetchedRole;
            isAdmin = fetchedAdmin;
            registrationStatus = providerData?['registration_status'] ?? 'incomplete';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            role = fetchedRole;
            isAdmin = fetchedAdmin;
          });
        }
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
    // Admin is first-class: an admin account goes straight to the Admin Panel,
    // never a customer/provider home. Driven by is_admin (role may also be 'admin').
    if (isAdmin || role == 'admin') return const AdminPanelScreen();
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
