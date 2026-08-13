-- Mark test accounts so the launch dashboard stops counting them as supply.
--
-- WHY: the admin panel said "3 providers can work" on 2026-08-13. All three
-- were test accounts — two of Vince's own and one of mine. The genuinely
-- recruited strangers were three people, one of whom reached approved and none
-- of whom could take a job. So the number he uses to decide whether there is
-- enough coverage to launch, to enable storm booking, or to market to
-- customers, was reporting his own test rigs as a workforce.
--
-- Same failure as everything else found this week: an instrument that reads
-- better than reality. Worse here, because it is the instrument the launch
-- decision rests on.
--
-- Test accounts are NOT hidden — you still need to see and manage them. They
-- are excluded from the READINESS numbers and carry a TEST chip so the two are
-- never confused again.

alter table public.users
  add column if not exists is_test boolean not null default false;

comment on column public.users.is_test is
  'Test/family account. Excluded from provider-readiness and customer counts in the admin panel so launch decisions are made on real supply only. Never hides the row.';

-- Seed the ones we know. Identified with Vince 2026-08-13.
--   John Doe / Alfonso Citarella  — his own test providers
--   Tony Palma                    — a friend testing on Android, not a provider
--   villacitarella+*              — his plus-addressed test signups
--   claude.test.*                 — mine
update public.users
   set is_test = true
 where email in (
        'amalficoastvacation@yahoo.com',   -- "John Doe"
        'alfonsocitarella1@yahoo.com',     -- Alfonso Citarella
        'antonio.mpiazza@gmail.com'        -- Tony Palma
      )
    or email like 'villacitarella+%'
    or email like 'claude.test.%';

-- Deliberately NOT marked, because these are the real pipeline and the whole
-- point is to see them clearly:
--   carbill999@gmail.com   scott mosby   (incomplete)
--   rarcboutique@gmail.com rosa ramirez  (incomplete)
--   safeson24@gmail.com    Isaiah        (approved, payouts never started)
