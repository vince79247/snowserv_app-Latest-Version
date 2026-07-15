-- ============================================================================
-- ⚠️  DO NOT APPLY UNTIL BUILD 5 SHIPS.  ⚠️  (RLS lockdown Stage 2, 2026-07-14)
-- ============================================================================
-- Stage 1 (20260714120000) closed the public/anon READ leak but kept WRITES loose
-- and let approved providers READ every job — because build 4's client dispatcher
-- reassigns jobs across providers and the customer writes the provider's rating
-- row directly. Stage 2 moves those cross-boundary operations to SECURITY DEFINER
-- RPCs, then TIGHTENS:
--   * provider READ → own jobs + the open queue only (a provider can no longer read
--     another provider's assigned/completed jobs, which is what protects the
--     admin-only jobs.provider_notes),
--   * WRITES → strict owner/admin (+ the atomic "grab a queued job" transition),
--   * column-level tamper guards on money (jobs) and status (users) columns,
--   * removes the anon INSERT on profiles/users/providers (the signup trigger
--     20260714130000 now creates those rows server-side).
--
-- COUPLING: build 5's client calls the new RPCs (rate_job / provider_release_job),
-- drops lib/utils/dispatch.dart, and no longer needs broad reads. Applying these
-- tight policies while build 4 is the live client WOULD BREAK build 4 (its
-- decline/cancel/dispatcher writes + job-board reads). So this is a build-5 cutover
-- migration ONLY — apply it AFTER the signup trigger (20260714130000) and once
-- build 5 is the client being tested. See PRELAUNCH.md "Build 5 cutover checklist".
-- ============================================================================

-- ============================================================================
-- 1. RPCs for the operations a tight policy can't allow client-side
-- ============================================================================

-- Customer rates their own COMPLETED job; we set the rating and recompute the
-- provider's average server-side (replaces the customer writing providers.rating).
create or replace function public.rate_job(p_job_id uuid, p_stars int)
returns void language plpgsql security definer set search_path = public as $$
declare v_provider uuid; v_avg numeric;
begin
  if p_stars < 1 or p_stars > 5 then raise exception 'stars must be 1..5'; end if;
  update public.jobs set customer_rating = p_stars
    where id = p_job_id and customer_id = auth.uid() and status = 'completed'
    returning provider_id into v_provider;
  if not found then raise exception 'not allowed'; end if;
  if v_provider is not null then
    select round(avg(customer_rating)::numeric, 1) into v_avg
      from public.jobs where provider_id = v_provider and customer_rating is not null;
    update public.providers set rating = v_avg where id = v_provider;
  end if;
end $$;
grant execute on function public.rate_job(uuid, int) to authenticated;

-- Provider declines an offer OR cancels an accepted/started job: verify the caller
-- holds it, drop them onto the rejected list, reset it to the queue, bump the
-- post-start-cancel counter if it was in progress, and immediately re-dispatch.
-- Returns was_in_progress so the client sends the right customer notification.
create or replace function public.provider_release_job(p_job_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_mine uuid[];
  v_status text; v_prov uuid; v_disp uuid; v_rejected text[];
  v_was_inprogress boolean;
  v_actor text;
begin
  select array_agg(id) into v_mine from public.providers where user_id = auth.uid();
  if v_mine is null then raise exception 'not a provider'; end if;

  select status, provider_id, dispatched_to, coalesce(rejected_providers, '{}')
    into v_status, v_prov, v_disp, v_rejected
    from public.jobs where id = p_job_id for update;
  if not found then raise exception 'job not found'; end if;

  if not ((v_prov = any(v_mine)) or (v_disp = any(v_mine))) then
    raise exception 'not your job';
  end if;

  v_was_inprogress := (v_status = 'in_progress');
  v_actor := coalesce(v_prov, v_disp)::text;

  update public.jobs set
    status = 'requested',
    provider_id = null,
    dispatched_to = null,
    dispatched_at = null,
    rejected_providers = array(
      select distinct e from unnest(v_rejected || array[v_actor]) as e)
  where id = p_job_id;

  if v_was_inprogress and v_prov is not null then
    update public.providers
      set cancelled_after_start_count = coalesce(cancelled_after_start_count, 0) + 1
      where id = v_prov;
  end if;

  perform public.dispatch_jobs();
  return v_was_inprogress;
end $$;
grant execute on function public.provider_release_job(uuid) to authenticated;

-- ============================================================================
-- 2. Tight READ + WRITE policies (replace the Stage-1 rls1_* ones)
-- ============================================================================

-- jobs -----------------------------------------------------------------------
drop policy if exists rls1_jobs_select on public.jobs;
drop policy if exists rls1_jobs_update on public.jobs;

-- Customer sees own; a provider sees jobs offered/assigned to them PLUS the open
-- queue (requested + unclaimed) so the "Jobs Waiting" board works; admin all. A
-- provider can NO LONGER read another provider's assigned/completed jobs → their
-- provider_notes stay private.
create policy rls2_jobs_select on public.jobs for select to authenticated
using (
  customer_id = auth.uid()
  or provider_id in (select public.my_provider_ids())
  or dispatched_to in (select public.my_provider_ids())
  or (status = 'requested' and dispatched_to is null and public.is_approved_provider())
  or public.is_admin()
);

-- Writes: customer on own; provider on their offered/assigned job or when atomically
-- claiming a queued one; admin all. Releasing a job (provider_id→null) is done by
-- provider_release_job (definer), so it isn't allowed here.
create policy rls2_jobs_update on public.jobs for update to authenticated
using (
  public.is_admin()
  or customer_id = auth.uid()
  or provider_id in (select public.my_provider_ids())
  or dispatched_to in (select public.my_provider_ids())
  or (status = 'requested' and dispatched_to is null and public.is_approved_provider())
)
with check (
  public.is_admin()
  or customer_id = auth.uid()
  or provider_id in (select public.my_provider_ids())
  or dispatched_to in (select public.my_provider_ids())
);

-- providers ------------------------------------------------------------------
drop policy if exists rls1_providers_select on public.providers;
drop policy if exists rls1_providers_insert on public.providers;
drop policy if exists rls1_providers_update on public.providers;

-- Own row; a customer may read the provider attached to one of their jobs; admin
-- all. (No more blanket approved-provider read — the client dispatcher is gone.)
create policy rls2_providers_select on public.providers for select to authenticated
using (
  user_id = auth.uid()
  or public.is_admin()
  or exists (select 1 from public.jobs j where j.provider_id = providers.id and j.customer_id = auth.uid())
);

-- Only the provider themselves (is_online, auto_accept, location, registration
-- fields, total_jobs) or an admin. rating is written by rate_job (definer). Signup
-- creates the row via the handle_new_user trigger (definer) — no client insert.
create policy rls2_providers_update on public.providers for update to authenticated
using (user_id = auth.uid() or public.is_admin())
with check (user_id = auth.uid() or public.is_admin());

-- users ----------------------------------------------------------------------
drop policy if exists rls1_users_select on public.users;
drop policy if exists rls1_users_insert on public.users;
drop policy if exists rls1_users_update on public.users;

-- Self + admin; a provider may read the customer (name/phone) ONLY for a job
-- offered/assigned to them (the active-jobs card embeds users). Job-scoped now.
create policy rls2_users_select on public.users for select to authenticated
using (
  id = auth.uid()
  or public.is_admin()
  or exists (
    select 1 from public.jobs j
    where j.customer_id = users.id
      and (j.provider_id in (select public.my_provider_ids())
           or j.dispatched_to in (select public.my_provider_ids())))
);

create policy rls2_users_update on public.users for update to authenticated
using (id = auth.uid() or public.is_admin())
with check (id = auth.uid() or public.is_admin());

-- addresses ------------------------------------------------------------------
drop policy if exists rls1_addresses_select on public.addresses;
drop policy if exists rls1_addresses_insert on public.addresses;
drop policy if exists rls1_addresses_update on public.addresses;

-- Owner + admin; a provider may read an address for a job offered/assigned to them
-- OR a queued job on the "Jobs Waiting" board (so they can see where before grabbing).
create policy rls2_addresses_select on public.addresses for select to authenticated
using (
  user_id = auth.uid()
  or public.is_admin()
  or (public.is_approved_provider() and exists (
      select 1 from public.jobs j
      where j.address_id = addresses.id
        and (j.provider_id in (select public.my_provider_ids())
             or j.dispatched_to in (select public.my_provider_ids())
             or (j.status = 'requested' and j.dispatched_to is null))))
);

create policy rls2_addresses_insert on public.addresses for insert to authenticated
with check (user_id = auth.uid());

create policy rls2_addresses_update on public.addresses for update to authenticated
using (user_id = auth.uid() or public.is_admin())
with check (user_id = auth.uid() or public.is_admin());

-- profiles: select/update stay as the tight Stage-1 self+admin policies. Only the
-- anon INSERT goes away (the signup trigger creates the row server-side now).
drop policy if exists rls1_profiles_insert on public.profiles;

-- ============================================================================
-- 3. Remove the anon signup-insert grants/policies (trigger owns row creation now)
-- ============================================================================
revoke insert on public.profiles, public.users, public.providers from anon;
-- waitlist anon insert stays (pre-signup quote). service_areas anon select stays.

-- ============================================================================
-- 4. Column-level tamper guards. RLS gates the ROW; these gate sensitive COLUMNS
--    so a user can't edit their OWN row's money/status fields. service_role (the
--    webhook/payout backend), postgres (migrations + SECURITY DEFINER RPCs) and
--    admins are exempt; everyone else is blocked from changing these columns.
-- ============================================================================
create or replace function public.guard_jobs_columns() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_user in ('postgres','service_role','supabase_admin','supabase_auth_admin')
     or public.is_admin() then
    return new;
  end if;
  -- (customer_rating is intentionally NOT guarded: it's the customer's own field
  -- and is written by the rate_job SECURITY DEFINER RPC — guarding it would risk
  -- self-blocking that RPC depending on its owner role.)
  if new.final_price       is distinct from old.final_price
     or new.base_price     is distinct from old.base_price
     or new.surge_multiplier is distinct from old.surge_multiplier
     or new.payment_intent_id is distinct from old.payment_intent_id
     or new.customer_id    is distinct from old.customer_id
     or new.payout_status  is distinct from old.payout_status then
    raise exception 'not allowed to modify protected job columns';
  end if;
  return new;
end $$;
drop trigger if exists guard_jobs_columns_trg on public.jobs;
create trigger guard_jobs_columns_trg before update on public.jobs
  for each row execute function public.guard_jobs_columns();

create or replace function public.guard_users_columns() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_user in ('postgres','service_role','supabase_admin','supabase_auth_admin')
     or public.is_admin() then
    return new;
  end if;
  if new.is_flagged       is distinct from old.is_flagged
     or new.is_suspended  is distinct from old.is_suspended
     or new.role          is distinct from old.role
     or new.stripe_customer_id is distinct from old.stripe_customer_id
     or new.card_pm_id    is distinct from old.card_pm_id then
    raise exception 'not allowed to modify protected user columns';
  end if;
  return new;
end $$;
drop trigger if exists guard_users_columns_trg on public.users;
create trigger guard_users_columns_trg before update on public.users
  for each row execute function public.guard_users_columns();

-- providers: a provider may edit their OWN operational fields (is_online, auto_accept,
-- location, crew/vehicle/insurance registration fields) and self-submit to
-- 'pending_review' — but must NOT self-APPROVE (registration_status approved/rejected
-- is admin-only) or touch verification / payout wiring / rating / preferred flag /
-- cancel counter (all set by admin or by SECURITY DEFINER server code, which is exempt).
create or replace function public.guard_providers_columns() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_user in ('postgres','service_role','supabase_admin','supabase_auth_admin')
     or public.is_admin() then
    return new;
  end if;
  if (new.registration_status is distinct from old.registration_status
        and coalesce(new.registration_status, '') <> 'pending_review')
     or new.is_verified   is distinct from old.is_verified
     or new.payouts_enabled is distinct from old.payouts_enabled
     or new.stripe_connect_id is distinct from old.stripe_connect_id
     or new.rating        is distinct from old.rating
     or new.preferred_until is distinct from old.preferred_until
     or new.cancelled_after_start_count is distinct from old.cancelled_after_start_count then
    raise exception 'not allowed to modify protected provider columns';
  end if;
  return new;
end $$;
drop trigger if exists guard_providers_columns_trg on public.providers;
create trigger guard_providers_columns_trg before update on public.providers
  for each row execute function public.guard_providers_columns();
