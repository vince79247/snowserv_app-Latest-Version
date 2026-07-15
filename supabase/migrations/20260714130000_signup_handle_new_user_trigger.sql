-- ============================================================================
-- ⚠️  DO NOT APPLY UNTIL BUILD 5 SHIPS.  ⚠️  (auth-edges leg, 2026-07-14)
-- ============================================================================
-- This trigger creates the profiles/users/providers rows on signup, SERVER-SIDE,
-- from the signUp() user-metadata (role/full_name/phone). It REPLACES the old
-- client-side inserts in auth_screen.dart, which ran as the anon role inside a
-- swallowed try/catch — so any failure silently orphaned the account (signup
-- "succeeded" but login could never find a profile row).
--
-- COUPLING: build 5's auth_screen no longer inserts these rows (it only passes
-- metadata). Build 4 (currently on TestFlight) STILL inserts them client-side.
-- If this trigger were applied while build 4 is the live client, the trigger and
-- the build-4 client would BOTH try to create the rows: the trigger would win
-- with role defaulted to 'customer' + blank name (build 4 doesn't send metadata),
-- corrupting provider signups. So this migration is applied at the build-5
-- cutover ONLY — never before. See PRELAUNCH.md "Build 5 cutover".
--
-- To apply at cutover: run this file via the Management API and record it in
-- supabase_migrations.schema_migrations (same flow as 20260714120000).
-- ============================================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role  text := coalesce(nullif(new.raw_user_meta_data->>'role', ''), 'customer');
  v_name  text := coalesce(new.raw_user_meta_data->>'full_name', '');
  v_phone text := new.raw_user_meta_data->>'phone';
begin
  insert into public.profiles (id, role, full_name, phone)
    values (new.id, v_role, v_name, v_phone)
    on conflict (id) do nothing;

  insert into public.users (id, name, email, phone, role)
    values (new.id, v_name, new.email, v_phone, v_role)
    on conflict (id) do nothing;

  if v_role = 'provider'
     and not exists (select 1 from public.providers where user_id = new.id) then
    insert into public.providers (user_id, is_online) values (new.id, false);
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
