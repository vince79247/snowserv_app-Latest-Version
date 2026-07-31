-- Let the ADMIN panel go live instead of polling.
--
-- Only public.jobs was in the supabase_realtime publication, so a client
-- subscription on providers/disputes would have connected happily and delivered
-- NOTHING — the failure mode where the code looks right and silently does
-- nothing. Adding them is what makes admin Realtime actually work.
--
-- SAFE TO BROADCAST: Realtime applies RLS per subscriber, and both tables have
-- scoped SELECT policies (verified 2026-07-30):
--   providers → rls2_providers_select: own row OR is_admin() OR a customer who
--               has a job with that provider
--   disputes  → "read own or admin": own row (either side) OR admin
-- So a customer subscribing sees only what they could already SELECT. No new
-- read surface is opened; this only changes HOW those rows are delivered.
--
-- Known limitation (accepted): DELETE events in postgres_changes emit only the
-- primary key and are not RLS-filtered. Neither table is ever hard-deleted in
-- normal operation, and a bare UUID discloses nothing useful.

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'providers'
  ) then
    alter publication supabase_realtime add table public.providers;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'disputes'
  ) then
    alter publication supabase_realtime add table public.disputes;
  end if;
end $$;
