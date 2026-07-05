import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';

// Single source of truth for the public Privacy Policy / Terms of Service URLs
// (published Google Docs). Referenced from the sign-up consent line and the
// in-app account menus, so a logged-in user can always reach them — not just at
// sign-up. (The App Store also wants the privacy policy accessible in-app.)
const String privacyPolicyUrl =
    'https://docs.google.com/document/d/e/2PACX-1vTs3QKh1Sh_d9RfCX4w1lgWhugWIld3VGiLSJnFHE5-Yd-qIj9v5rrrI8FMYTtYa85aY2aP2-aKFHRi/pub';
const String termsOfServiceUrl =
    'https://docs.google.com/document/d/e/2PACX-1vTcXcBxj_5lSgLWeWzPpPFWxSmA1BOjMgNs1fdFg1NFqZnIEWtluIwCyXbJLpnttfc0vD2Mts6IZcxb/pub';

Future<void> openLegalUrl(String url) async {
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Account-menu rows for Privacy Policy and Terms of Service. Each pops the
/// containing sheet (using [context]) then opens the doc in the browser.
List<Widget> legalMenuTiles(BuildContext context) => [
      ListTile(
        leading: const Icon(Icons.privacy_tip_outlined, color: SnowServColors.navy),
        title: const Text('Privacy Policy'),
        trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
        onTap: () {
          Navigator.pop(context);
          openLegalUrl(privacyPolicyUrl);
        },
      ),
      ListTile(
        leading: const Icon(Icons.description_outlined, color: SnowServColors.navy),
        title: const Text('Terms of Service'),
        trailing: const Icon(Icons.open_in_new, size: 16, color: Colors.grey),
        onTap: () {
          Navigator.pop(context);
          openLegalUrl(termsOfServiceUrl);
        },
      ),
    ];

/// "By creating an account, you agree to our Terms of Service and Privacy
/// Policy." with the two documents tappable. Stateful so the tap recognizers
/// are disposed properly. Shown next to the sign-up button.
class LegalConsentText extends StatefulWidget {
  final Color textColor;
  final Color linkColor;
  const LegalConsentText({
    super.key,
    this.textColor = Colors.white54,
    this.linkColor = Colors.white,
  });

  @override
  State<LegalConsentText> createState() => _LegalConsentTextState();
}

class _LegalConsentTextState extends State<LegalConsentText> {
  late final TapGestureRecognizer _termsTap;
  late final TapGestureRecognizer _privacyTap;

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()..onTap = () => openLegalUrl(termsOfServiceUrl);
    _privacyTap = TapGestureRecognizer()..onTap = () => openLegalUrl(privacyPolicyUrl);
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final linkStyle = TextStyle(
      color: widget.linkColor,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      decoration: TextDecoration.underline,
      decorationColor: widget.linkColor,
    );
    return Text.rich(
      TextSpan(
        style: TextStyle(color: widget.textColor, fontSize: 12, height: 1.4),
        children: [
          const TextSpan(text: 'By creating an account, you agree to our '),
          TextSpan(text: 'Terms of Service', style: linkStyle, recognizer: _termsTap),
          const TextSpan(text: ' and '),
          TextSpan(text: 'Privacy Policy', style: linkStyle, recognizer: _privacyTap),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
