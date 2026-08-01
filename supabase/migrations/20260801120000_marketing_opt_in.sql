-- Explicit consent for NON-operational email.
--
-- The Terms already promise this: operational mail (order/job status, dispatch
-- and arrival notices, cancellations, receipts, account + security) is covered by
-- having an account, but "marketing messages only if you separately opt in, and
-- you can opt out of those at any time." There was no way to RECORD that opt-in —
-- a promise with no plumbing behind it.
--
-- Doing it pre-launch on purpose: every customer acquired from here arrives with
-- a timestamped consent record. Retrofitting after the first cohort means those
-- people are effectively unmailable forever — re-permission campaigns get
-- single-digit response rates. It also protects the sending domain we just
-- authenticated; a consented list is what keeps deliverability healthy.
--
-- Default FALSE, and the signup checkbox ships UNCHECKED. Opt-in must be an act,
-- not a thing that happened to someone who didn't read carefully.

alter table public.users
  add column if not exists marketing_opt_in boolean not null default false;

-- When they said yes (or most recently changed it) — the evidence half of consent.
-- A bare boolean can't answer "prove they agreed, and when".
alter table public.users
  add column if not exists marketing_opt_in_at timestamptz;

comment on column public.users.marketing_opt_in is
  'Consent for NON-operational email (season opening, service-area expansion, '
  're-engagement). Operational mail does not depend on this. Terms promise '
  'marketing is opt-in only — see website/terms.html.';

-- Carry the checkbox through signup. The client cannot write these rows (they are
-- created by this SECURITY DEFINER trigger), so the value rides in auth metadata
-- exactly like role/full_name/phone.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role  text := coalesce(nullif(new.raw_user_meta_data->>'role', ''), 'customer');
  v_name  text := coalesce(new.raw_user_meta_data->>'full_name', '');
  v_phone text := new.raw_user_meta_data->>'phone';
  -- Anything other than an explicit true is a no. A missing key (older app build)
  -- must never be read as consent.
  v_optin boolean := (new.raw_user_meta_data->>'marketing_opt_in') = 'true';
begin
  insert into public.profiles (id, role, full_name, phone)
    values (new.id, v_role, v_name, v_phone)
    on conflict (id) do nothing;

  insert into public.users (id, name, email, phone, role, marketing_opt_in, marketing_opt_in_at)
    values (new.id, v_name, new.email, v_phone, v_role,
            v_optin, case when v_optin then now() else null end)
    on conflict (id) do nothing;

  if v_role = 'provider'
     and not exists (select 1 from public.providers where user_id = new.id) then
    insert into public.providers (user_id, is_online) values (new.id, false);
  end if;

  return new;
end;
$function$;
