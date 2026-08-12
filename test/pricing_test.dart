// Guards the "shown price == charged price" invariant on the app side.
//
// The SAME cases are run against the server's TypeScript implementation by
// supabase/functions/_shared/pricing_test.ts. If someone edits the math in one
// language, the other language's suite fails — which is the point. Before this,
// three copies of this arithmetic were kept in sync by a comment asking the
// next reader to be careful.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:snowserv_app/utils/pricing.dart';

void main() {
  final raw = File('test/pricing_cases.json').readAsStringSync();
  final fixture = jsonDecode(raw) as Map<String, dynamic>;
  final zones = fixture['zones'] as Map<String, dynamic>;
  final cases = fixture['cases'] as List<dynamic>;
  final typeCases = fixture['serviceTypeCases'] as List<dynamic>;

  group('priceOrder matches the shared golden cases', () {
    for (final c in cases) {
      final tc = c as Map<String, dynamic>;
      test(tc['name'] as String, () {
        final zoneKey = tc['zone'] as String?;
        final zone = zoneKey == null
            ? null
            : Map<String, dynamic>.from(zones[zoneKey] as Map);
        final expected = tc['expect'] as Map<String, dynamic>;

        final got = priceOrder(
          zone: zone,
          wantsWalkway: tc['walkway'] as bool,
          wantsDriveway: tc['driveway'] as bool,
          wantsSalting: (tc['salting'] as bool?) ?? false,
          addressMultiplier:
              ((tc['addressMultiplier'] as num?) ?? 1).toDouble(),
          surge: ((tc['surge'] as num?) ?? 1).toDouble(),
        );

        expect(got.service, expected['service'], reason: 'service price');
        expect(got.salting, expected['salting'], reason: 'deicer price');
        expect(got.base, expected['base'], reason: 'base total');
        expect(got.finalPrice, expected['final'], reason: 'final charged price');
      });
    }
  });

  group('service_type maps to the same surfaces the server assumes', () {
    for (final c in typeCases) {
      final tc = c as Map<String, dynamic>;
      test('${tc['serviceType']}', () {
        final s = surfacesForServiceType(tc['serviceType'] as String);
        expect(s.walkway, tc['walkway']);
        expect(s.driveway, tc['driveway']);
      });
    }

    test('an unknown service_type bills as both, never as free', () {
      // trigger-storm-bookings derives surfaces by NEGATION
      // (walkway: type !== 'driveway'), so an unrecognized value lands on both.
      // Matching that here means a bad value can never silently produce a $0
      // job — it produces the most expensive reading, which someone notices.
      final s = surfacesForServiceType('something_new');
      expect(s.walkway, isTrue);
      expect(s.driveway, isTrue);
    });
  });

  group('regressions worth naming', () {
    test('deicer never costs more than the shoveling it accompanies', () {
      // The bug that forced the per-surface split: one flat $90 deicer fee made
      // a sidewalk-only order cost more to salt than to clear.
      final zone = Map<String, dynamic>.from(zones['standard'] as Map);
      final sidewalkOnly = priceOrder(
        zone: zone, wantsWalkway: true, wantsDriveway: false, wantsSalting: true);
      expect(sidewalkOnly.salting, lessThan(sidewalkOnly.service));
    });

    test('a zone missing the per-surface columns never prices deicer at 0', () {
      // An uncoalesced read here would hand the customer free deicer and pay
      // the provider 75% of a number that never included it.
      final legacy = Map<String, dynamic>.from(zones['legacy_flat_deicer'] as Map);
      for (final surfaces in [
        (walkway: true, driveway: false),
        (walkway: false, driveway: true),
        (walkway: true, driveway: true),
      ]) {
        final p = priceOrder(
          zone: legacy,
          wantsWalkway: surfaces.walkway,
          wantsDriveway: surfaces.driveway,
          wantsSalting: true);
        expect(p.salting, greaterThan(0),
            reason: 'legacy zone, walkway=${surfaces.walkway} '
                'driveway=${surfaces.driveway}');
      }
    });

    test('storm surge multiplies the per-address price, it does not replace it', () {
      final zone = Map<String, dynamic>.from(zones['standard'] as Map);
      final plain = priceOrder(
        zone: zone, wantsWalkway: true, wantsDriveway: true);
      final premium = priceOrder(
        zone: zone, wantsWalkway: true, wantsDriveway: true,
        addressMultiplier: 2.0, surge: 1.5);
      expect(premium.finalPrice, (plain.finalPrice * 2 * 1.5).round());
    });

    test('no zone can never produce a chargeable amount', () {
      final p = priceOrder(
        zone: null, wantsWalkway: true, wantsDriveway: true,
        wantsSalting: true, addressMultiplier: 5.0, surge: 2.0);
      expect(p.finalPrice, 0);
    });
  });
}
