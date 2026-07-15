-- ============================================================================
-- RLS LOCKDOWN — STAGE 1: close the public / anon-key READ leak.
-- ============================================================================
-- Problem (proven 2026-07-14 by probing the REST API with the PUBLIC anon key,
-- unauthenticated): jobs (151 rows), addresses (14), users (4) and providers (2)
-- were fully readable by anyone holding the anon key — which is shipped inside
-- the iOS app and the marketing site. That leaks customer home addresses +
-- lat/lng, names/emails/phones, card brand/last4, payment_intent_ids and the
-- ADMIN-ONLY jobs.provider_notes. This migration makes the database refuse the
-- anon key (and cross-customer reads) for every private table.
--
-- SCOPE — Stage 1 is deliberately READ-focused and 100% backward compatible with
-- the current app + build (no client change, no new build required):
--   * SELECT is locked down per-role (the actual fix).
--   * WRITES stay permissive for LOGGED-IN users so nothing breaks — the client
--     dispatcher (an authenticated provider reassigning jobs), the customer→
--     provider rating write, provider accept/start/complete, etc. all keep
--     working. anon can no longer write anything except the two signup/lead
--     paths that legitimately run before a session exists (see below).
--   * SIGNUP TIMING: with email-confirmation ON, signUp() returns NO session, so
--     auth_screen inserts profiles/users/providers as the ANON role. Those INSERT
--     paths are therefore explicitly allowed for anon here — otherwise signup
--     would fail silently and users could never log in. Stage 2 replaces this
--     with an auth.users trigger and removes the anon INSERT grant.
--
-- Stage 2 (rides on the next build): move the dispatcher, the rating write and
-- signup-row creation to SECURITY DEFINER RPCs / a trigger, then tighten the
-- WRITE policies to strict owner/admin-only, tighten provider READ to job-scoped
-- (so a provider can't read jobs — and provider_notes — that aren't theirs), and
-- add column-level tamper protection (is_flagged/is_suspended/final_price/role).
--
-- Reversible: `alter table <t> disable row level security;` instantly restores
-- the pre-migration behavior if anything regresses.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helper functions. All SECURITY DEFINER so they read their source table with
-- the owner's rights and BYPASS RLS — this both avoids policy recursion (a
-- profiles policy calling is_admin() which itself reads profiles) and lets a
-- provider's job-scoped checks read the providers table.
-- ----------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false);
$$;
grant execute on function public.is_admin() to anon, authenticated;

create or replace function public.is_approved_provider()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.providers pr
    where pr.user_id = auth.uid() and pr.registration_status = 'approved'
  );
$$;
grant execute on function public.is_approved_provider() to authenticated;

create or replace function public.my_provider_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from public.providers where user_id = auth.uid();
$$;
grant execute on function public.my_provider_ids() to authenticated;

-- ----------------------------------------------------------------------------
-- DROP the legacy wide-open policies. These are the actual leak: inspection of
-- the live DB (2026-07-14) showed RLS was already ENABLED but the policies were
-- `USING true` / anon-select, so the anon key could read everything. Policies
-- are OR'd (permissive), so a single `true` policy defeats every scoped one —
-- they MUST be removed, not just added alongside. app_settings + disputes
-- policies are already correct and are left in place.
-- ----------------------------------------------------------------------------
drop policy if exists "Allow anon select"            on public.jobs;
drop policy if exists "Allow anon insert"            on public.jobs;
drop policy if exists "Authenticated can select jobs" on public.jobs;
drop policy if exists "Authenticated can update jobs" on public.jobs;
drop policy if exists "Customers can insert jobs"     on public.jobs;
drop policy if exists "Providers can manage own record" on public.providers;
drop policy if exists "Users can select records"      on public.users;
drop policy if exists "Users can insert own record"   on public.users;
drop policy if exists "Users can update own record"   on public.users;
drop policy if exists "Users can manage own addresses" on public.addresses;
drop policy if exists "Users can view own profile"    on public.profiles;
drop policy if exists "Users can insert own profile"  on public.profiles;
drop policy if exists "Users can update own profile"  on public.profiles;
drop policy if exists "service_areas read"            on public.service_areas;
drop policy if exists "service_areas write"           on public.service_areas;
drop policy if exists "waitlist insert"               on public.waitlist;
drop policy if exists "waitlist read"                 on public.waitlist;

-- ----------------------------------------------------------------------------
-- jobs — customer sees own; a provider sees jobs offered/assigned to them, plus
-- (Stage 1) any job while they're an approved provider because the client-side
-- dispatcher still reads across jobs to rank load. Stage 2 removes that broad
-- read. anon: nothing. Writes: any logged-in user (Stage-1 permissive); anon
-- cannot write; no client path inserts/deletes jobs (the Stripe webhook does,
-- via service_role, which bypasses RLS).
-- ----------------------------------------------------------------------------
alter table public.jobs enable row level security;

drop policy if exists rls1_jobs_select on public.jobs;
create policy rls1_jobs_select on public.jobs for select to authenticated
using (
  customer_id = auth.uid()
  or provider_id in (select public.my_provider_ids())
  or dispatched_to in (select public.my_provider_ids())
  or public.is_approved_provider()
  or public.is_admin()
);

drop policy if exists rls1_jobs_update on public.jobs;
create policy rls1_jobs_update on public.jobs for update to authenticated
using (true) with check (true);

-- ----------------------------------------------------------------------------
-- providers — own row; approved providers (dispatcher ranks over all providers);
-- a customer may read the provider attached to one of their jobs; admin all.
-- INSERT allowed for anon (provider signup runs pre-session). Writes otherwise
-- permissive for logged-in users (Stage-1: covers provider self-updates AND the
-- customer→provider rating write).
-- ----------------------------------------------------------------------------
alter table public.providers enable row level security;

drop policy if exists rls1_providers_select on public.providers;
create policy rls1_providers_select on public.providers for select to authenticated
using (
  user_id = auth.uid()
  or public.is_approved_provider()
  or public.is_admin()
  or exists (select 1 from public.jobs j where j.provider_id = providers.id and j.customer_id = auth.uid())
);

drop policy if exists rls1_providers_insert on public.providers;
create policy rls1_providers_insert on public.providers for insert to anon, authenticated
with check (true);

drop policy if exists rls1_providers_update on public.providers;
create policy rls1_providers_update on public.providers for update to authenticated
using (true) with check (true);

-- ----------------------------------------------------------------------------
-- profiles — self + admin read/update. INSERT allowed for anon (signup).
-- ----------------------------------------------------------------------------
alter table public.profiles enable row level security;

drop policy if exists rls1_profiles_select on public.profiles;
create policy rls1_profiles_select on public.profiles for select to authenticated
using (id = auth.uid() or public.is_admin());

drop policy if exists rls1_profiles_insert on public.profiles;
create policy rls1_profiles_insert on public.profiles for insert to anon, authenticated
with check (true);

drop policy if exists rls1_profiles_update on public.profiles;
create policy rls1_profiles_update on public.profiles for update to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

-- ----------------------------------------------------------------------------
-- users — self + admin; a provider may read the customer on their job (the
-- provider queue embeds users(name, phone)); Stage-1 broad provider read. anon
-- INSERT for signup. Writes permissive for logged-in users (Stage 2 adds a
-- trigger blocking self-edits of is_flagged/is_suspended/role/card/stripe).
-- ----------------------------------------------------------------------------
alter table public.users enable row level security;

drop policy if exists rls1_users_select on public.users;
create policy rls1_users_select on public.users for select to authenticated
using (id = auth.uid() or public.is_admin() or public.is_approved_provider());

drop policy if exists rls1_users_insert on public.users;
create policy rls1_users_insert on public.users for insert to anon, authenticated
with check (true);

drop policy if exists rls1_users_update on public.users;
create policy rls1_users_update on public.users for update to authenticated
using (true) with check (true);

-- ----------------------------------------------------------------------------
-- addresses — owner + admin; a provider may read the address of their job (the
-- provider queue embeds addresses(*)). INSERT scoped to the owner. UPDATE
-- permissive for logged-in users (customer edits own; admin sets price_multiplier).
-- ----------------------------------------------------------------------------
alter table public.addresses enable row level security;

drop policy if exists rls1_addresses_select on public.addresses;
create policy rls1_addresses_select on public.addresses for select to authenticated
using (user_id = auth.uid() or public.is_admin() or public.is_approved_provider());

drop policy if exists rls1_addresses_insert on public.addresses;
create policy rls1_addresses_insert on public.addresses for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists rls1_addresses_update on public.addresses;
create policy rls1_addresses_update on public.addresses for update to authenticated
using (true) with check (true);

-- ----------------------------------------------------------------------------
-- service_areas — PUBLIC read (the pre-signup quote reads zones with the anon
-- key); writes admin-only (zone editor / activate / delete).
-- ----------------------------------------------------------------------------
alter table public.service_areas enable row level security;

drop policy if exists rls1_service_areas_select on public.service_areas;
create policy rls1_service_areas_select on public.service_areas for select to anon, authenticated
using (true);

drop policy if exists rls1_service_areas_write on public.service_areas;
create policy rls1_service_areas_write on public.service_areas for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- ----------------------------------------------------------------------------
-- waitlist — anyone may add themselves (pre-signup quote + in-app banner run as
-- anon or authenticated); only admins may read the list.
-- ----------------------------------------------------------------------------
alter table public.waitlist enable row level security;

drop policy if exists rls1_waitlist_insert on public.waitlist;
create policy rls1_waitlist_insert on public.waitlist for insert to anon, authenticated
with check (true);

drop policy if exists rls1_waitlist_select on public.waitlist;
create policy rls1_waitlist_select on public.waitlist for select to authenticated
using (public.is_admin());

-- ----------------------------------------------------------------------------
-- Grants: make sure the roles still hold the base table privileges RLS layers
-- on top of (Supabase's defaults usually cover these; assert the anon signup +
-- lead + quote paths explicitly).
-- ----------------------------------------------------------------------------
grant insert on public.profiles, public.users, public.providers, public.waitlist to anon;
grant select on public.service_areas to anon;

-- app_settings and disputes are already RLS-locked (read-public/admin-write and
-- party/admin respectively) from earlier migrations — left untouched here.
