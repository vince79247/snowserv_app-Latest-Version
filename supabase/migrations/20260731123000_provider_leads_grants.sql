-- Table-level GRANTs for provider_leads.
--
-- RLS policies alone are NOT enough: they filter what a role is already
-- permitted to touch. A new table created in a migration gets no DML privileges
-- for anon/authenticated, so the policies written in 20260731120000 were
-- unreachable — anon INSERT returned 401 and SELECT returned 42501 "permission
-- denied for table" (caught by probing it rather than trusting the policies).
--
-- Deliberately TIGHTER than public.waitlist, which grants anon full
-- SELECT/INSERT/UPDATE/DELETE and relies on RLS for all of its protection. Here
-- anon gets INSERT only, so the public form works while a scrapeable list of
-- local contractors' names, emails and phones is blocked at two independent
-- layers instead of one.

grant insert on public.provider_leads to anon;
grant select, insert, update, delete on public.provider_leads to authenticated;
grant all on public.provider_leads to service_role;
