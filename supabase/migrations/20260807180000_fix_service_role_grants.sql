-- service_role grants for every table created by raw SQL.
--
-- THIRD time this exact bug bit in one day (2026-08-07): email_log couldn't be
-- read by the admin panel, account_deletion_feedback silently swallowed every
-- exit survey, and storm_bookings returned "permission denied" to its own cron
-- — which my trigger function then reported as "0 bookings" because it checked
-- Array.isArray() instead of checking for an error.
--
-- ROOT CAUSE, worth stating once so nobody rediscovers it a fourth time: tables
-- created through the Supabase dashboard inherit SELECT/INSERT/UPDATE/DELETE
-- for anon, authenticated and service_role. Tables created by raw SQL through
-- the Management API DO NOT — they come out with REFERENCES/TRIGGER/TRUNCATE
-- and nothing useful. RLS policies are then written against a table nobody has
-- the table-level privilege to touch, and Postgres checks the privilege FIRST,
-- so the policies never even run. Every failure is a silent empty result.
--
-- RULE: after creating a table by raw SQL, always GRANT explicitly, and verify
-- with information_schema.role_table_grants. A "policy created" message is not
-- evidence that anybody can read the table.
--
-- service_role bypasses RLS but still needs the table privilege — that is the
-- part that keeps getting missed, because "bypasses RLS" reads like "bypasses
-- everything".
--
-- anon is deliberately NOT granted anything here. These are all private tables;
-- the only public-read table is service_areas (for the pre-signup quote).

grant select, insert, update, delete on public.storm_bookings to service_role;
grant select, insert, update, delete on public.operator_network to service_role;

-- Already correct, restated so this migration is the single answer to "who can
-- touch what" for the tables we added ourselves.
grant select, insert on public.email_log to service_role;
grant select, insert on public.account_deletion_feedback to service_role;
grant select, insert, update, delete on public.address_notes to service_role;
grant select, insert, update, delete on public.provider_leads to service_role;
