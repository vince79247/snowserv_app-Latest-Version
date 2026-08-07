-- Table GRANTS for the two tables I added by raw SQL. Without these, RLS never
-- even gets consulted.
--
-- Postgres checks the table-level privilege FIRST and the row-level policy
-- second. Both email_log and account_deletion_feedback were created with a
-- careful set of RLS policies and no grants at all, so `authenticated` held
-- REFERENCES/TRIGGER/TRUNCATE and nothing else — no SELECT, no INSERT. The
-- policies were correct and completely unreachable.
--
-- Two live consequences, both silent because both call sites swallow errors:
--   * the admin panel's email_log read returned permission denied, so the
--     "Emailed" chip could never appear — which is exactly what Vince reported
--     seeing (or rather, not seeing) on Jose's card.
--   * the account-deletion exit survey had been failing since it was built. It
--     is deliberately written to swallow every failure so that nothing can
--     block a deletion, and it dutifully swallowed this one.
--
-- Compare a table created earlier through the normal path (waitlist,
-- provider_leads): SELECT/INSERT/UPDATE/DELETE for authenticated and
-- service_role. Supabase's default privileges did not apply to these two.
--
-- LESSON, worth stating because it will happen again: after creating a table by
-- raw SQL, check information_schema.role_table_grants, not just the policies.
-- A green "policy created" is not evidence that anyone can read the table.

-- Admin-only read; RLS (is_admin()) does the actual restricting.
grant select on public.email_log to authenticated;
-- service_role bypasses RLS but still needs the table privilege. The edge
-- functions write here after a send confirms.
grant select, insert on public.email_log to service_role;

-- Written by the departing user while still signed in; read by admins. Both
-- narrowed by the policies already on the table.
grant select, insert on public.account_deletion_feedback to authenticated;
grant select, insert on public.account_deletion_feedback to service_role;
