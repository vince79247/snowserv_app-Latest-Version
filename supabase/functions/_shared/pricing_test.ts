// Server-side half of the "shown price == charged price" guard.
//
// Runs the SAME cases as test/pricing_test.dart, from the same file. Edit the
// math in either language and one of the two suites goes red.
//
//   deno test --allow-read supabase/functions/_shared/pricing_test.ts
//
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { priceOrder, surfacesForServiceType } from './pricing.ts'

interface Fixture {
  zones: Record<string, Record<string, unknown>>
  cases: Array<{
    name: string
    zone: string | null
    walkway: boolean
    driveway: boolean
    salting?: boolean
    addressMultiplier?: number
    surge?: number
    expect: { service: number; salting: number; base: number; final: number }
  }>
  serviceTypeCases: Array<{ serviceType: string; walkway: boolean; driveway: boolean }>
}

const fixture: Fixture = JSON.parse(
  await Deno.readTextFile(new URL('../../../test/pricing_cases.json', import.meta.url)),
)

for (const c of fixture.cases) {
  Deno.test(`golden: ${c.name}`, () => {
    const zone = c.zone === null ? null : fixture.zones[c.zone]
    const got = priceOrder({
      zone,
      wantsWalkway: c.walkway,
      wantsDriveway: c.driveway,
      wantsSalting: c.salting ?? false,
      addressMultiplier: c.addressMultiplier ?? 1,
      surge: c.surge ?? 1,
    })
    assertEquals(got.service, c.expect.service, 'service price')
    assertEquals(got.salting, c.expect.salting, 'deicer price')
    assertEquals(got.base, c.expect.base, 'base total')
    assertEquals(got.finalPrice, c.expect.final, 'final charged price')
  })
}

for (const c of fixture.serviceTypeCases) {
  Deno.test(`service_type surfaces: ${c.serviceType}`, () => {
    const s = surfacesForServiceType(c.serviceType)
    assertEquals(s.walkway, c.walkway)
    assertEquals(s.driveway, c.driveway)
  })
}

Deno.test('an unknown service_type bills as both, never as free', () => {
  assertEquals(surfacesForServiceType('something_new'), { walkway: true, driveway: true })
  assertEquals(surfacesForServiceType(null), { walkway: true, driveway: true })
})

Deno.test('a zone missing the per-surface deicer columns never prices it at 0', () => {
  const legacy = fixture.zones['legacy_flat_deicer']
  for (const s of [
    { walkway: true, driveway: false },
    { walkway: false, driveway: true },
    { walkway: true, driveway: true },
  ]) {
    const p = priceOrder({
      zone: legacy, wantsWalkway: s.walkway, wantsDriveway: s.driveway, wantsSalting: true,
    })
    if (p.salting <= 0) {
      throw new Error(`legacy zone priced deicer at ${p.salting} for ${JSON.stringify(s)}`)
    }
  }
})

Deno.test('no zone can never produce a chargeable amount', () => {
  const p = priceOrder({
    zone: null, wantsWalkway: true, wantsDriveway: true, wantsSalting: true,
    addressMultiplier: 5, surge: 2,
  })
  assertEquals(p.finalPrice, 0)
})
