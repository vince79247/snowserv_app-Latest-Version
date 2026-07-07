import 'package:flutter/material.dart';

/// Max width of the centered web content column. The app UI is phone-first, so
/// on a wide desktop browser most screens are capped to a phone-ish column
/// (see MaterialApp.builder in main.dart). The admin panel is the exception —
/// it's a data-heavy back-office screen that wants the full browser width.
const double kPhoneWebWidth = 520;
const double kAdminWebWidth = double.infinity; // full browser width

/// Drives the web content-column width. Bumped to full width while the admin
/// panel is open, restored to the phone width on exit.
final ValueNotifier<double> webContentMaxWidth = ValueNotifier<double>(kPhoneWebWidth);

/// Opens the admin panel, widening the web column to full width BEFORE the panel
/// builds (so there's no resize flash) and restoring the phone width when it
/// closes. On mobile the notifier is unused (the builder only caps width on
/// web), so this is effectively a plain push there.
void openAdminPanel(BuildContext context, Widget adminScreen) {
  webContentMaxWidth.value = kAdminWebWidth;
  Navigator.push(context, MaterialPageRoute(builder: (_) => adminScreen))
      .whenComplete(() => webContentMaxWidth.value = kPhoneWebWidth);
}
