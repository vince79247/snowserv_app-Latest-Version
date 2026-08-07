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

  // The photo ID step accepts ANY government ID, not just a driver's license
  // (Vince, 2026-08-07: requiring a license shuts out everyone who doesn't
  // drive, for no gain). A passport has no issuing state, so requiring one
  // would make that option impossible to submit — pin both facts.
  testWidgets('Photo ID step takes any government ID, and a passport needs no state',
      (tester) async {
    await pumpRegistration(tester, const Size(390, 844));

    // Advance past Equipment (which no longer blocks) to the ID step.
    await tester.ensureVisible(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Photo ID'), findsWidgets,
        reason: 'The identity step should be titled for a photo ID');
    expect(find.text('ID number'), findsOneWidget);
    expect(find.text('State'), findsOneWidget,
        reason: 'A license/state ID does have an issuing state');

    // Tap the dropdown itself, not its floating label — the label sits inside
    // the input decoration and a tap there does not reliably hit test.
    await tester.tap(find.byKey(const Key('idTypeDropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('U.S. passport').last);
    await tester.pumpAndSettle();

    expect(find.text('State'), findsNothing,
        reason: 'A passport has no issuing state, so the field must disappear — '
            'otherwise the step can never be completed');
    expect(tester.takeException(), isNull);
  });
}
