import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:snowserv_app/screens/provider/provider_registration_screen.dart';

/// Layout regression tests for the first screen a contractor ever sees.
///
/// Why this file exists: on 2026-08-06 the equipment dropdown rendered its
/// label past its own border on a phone, and the only reason we found out was
/// Vince opening the app and looking at it. `flutter analyze` cannot see
/// layout — but a widget test can, because Flutter reports a RenderFlex
/// overflow as a real exception during a test.
///
/// These render at true iPhone logical sizes, smallest first. If a label,
/// button or row ever stops fitting, this goes red before anyone installs it.
void main() {
  // 375x667 = iPhone SE, the narrowest screen we realistically support and the
  // one that breaks first. 390x844 = iPhone 14/15/16/17 class.
  const sizes = <String, Size>{
    'iPhone SE (375x667)': Size(375, 667),
    'iPhone 15/17 (390x844)': Size(390, 844),
  };

  Future<void> pumpRegistration(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: ProviderRegistrationScreen()),
    );
    await tester.pump();
  }

  sizes.forEach((label, size) {
    testWidgets('Equipment step lays out with no overflow on $label',
        (tester) async {
      await pumpRegistration(tester, size);
      expect(tester.takeException(), isNull,
          reason: 'Something overflowed its bounds on $label');
    });

    testWidgets('Selecting each equipment type does not overflow on $label',
        (tester) async {
      await pumpRegistration(tester, size);

      // Plow truck is the interesting one: choosing it reveals the truck
      // fields, so it renders a materially different layout from the others.
      for (final choice in ['Snowblower', 'Plow truck', 'Shovel only']) {
        final card = find.text(choice);
        expect(card, findsOneWidget, reason: '"$choice" option is missing');
        // Scroll it into view first. On a 390x844 phone the third option sits
        // right at the bottom edge, so a blind tap lands on nothing — which is
        // also a fair warning that the option is below the fold on real phones.
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'Choosing "$choice" overflowed on $label');
      }
    });
  });

  testWidgets('Truck fields appear only for a plow truck', (tester) async {
    await pumpRegistration(tester, const Size(390, 844));

    // Shovel is the default, and a shovel provider must never be asked for a
    // plate — that over-ask is what dragged them into insurance they did not
    // need. See the equipment/vehicle rework on 2026-08-06.
    expect(find.text('License Plate'), findsNothing);

    await tester.ensureVisible(find.text('Plow truck'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plow truck'));
    await tester.pumpAndSettle();
    expect(find.text('License Plate'), findsOneWidget);

    // VIN was removed deliberately — 17 characters you have to walk out to the
    // truck to read. It must not come back.
    expect(find.text('VIN'), findsNothing,
        reason: 'VIN was removed from registration and should stay removed');
  });
  // Registration collects NO identity documents. Stripe Connect verifies
  // identity properly during payout onboarding — legal name, DOB, address and
  // SSN checked against government records before it will move money — so our
  // own copy bought an admin squinting at a photo while making us hold the
  // riskiest data we touch. Decided with Vince 2026-08-07.
  //
  // This test exists so the step cannot quietly come back: an ID field here
  // means we are storing license numbers again.
  testWidgets('Registration asks for no identity documents', (tester) async {
    await pumpRegistration(tester, const Size(390, 844));

    const banned = [
      'ID number',
      'Photo ID',
      "Driver's License #",
      'Upload your photo ID',
      'Type of ID',
    ];

    // Walk every step, not just the first — the field could reappear anywhere.
    for (var step = 0; step < 4; step++) {
      for (final label in banned) {
        expect(find.text(label), findsNothing,
            reason: '"$label" is back on step $step. Identity verification '
                'belongs to Stripe, not to us.');
      }
      final next = find.text('Continue');
      if (next.evaluate().isEmpty) break;
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
}
