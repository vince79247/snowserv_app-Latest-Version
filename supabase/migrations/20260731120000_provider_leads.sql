-- Provider recruiting pipeline.
--
-- WHY: snow demand is spiky and non-deferrable — a storm arrives and everyone
-- wants service in the same six hours, and you CANNOT recruit providers mid-storm
-- because everyone capable is already out working. Supply has to exist before the
-- first flake. Landscapers (idle Dec–Mar, already equipped) decide their winter
-- income plan in Sept/Oct, so outreach starts ~6 weeks from now and needs
-- somewhere to land that isn't a spreadsheet.
--
-- There is a customer `waitlist` for unserved ZIPs but no provider equivalent, so
-- an interested landscaper who isn't ready to complete a full registration today
-- has nowhere to go. This is that.

create table if not exists public.provider_leads (
  id           uuid primary key default gen_random_uuid(),
  name         text,
  email        text,
  phone        text,
  zip          text,
  -- Free text on purpose: at lead stage we're capturing what someone SAYS they
  -- run ("2 trucks w/ plows, couple of blowers"), not a validated enum. The
  -- structured providers.equipment value gets set at real registration.
  equipment    text,
  company      text,
  -- Where the lead came from, so Vince can tell which channel actually works
  -- (landscaper cold call vs Facebook group vs referral vs the public form).
  source       text,
  notes        text,
  status       text not null default 'new',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table public.provider_leads
  drop constraint if exists provider_leads_status_check;
alter table public.provider_leads
  add constraint provider_leads_status_check
  check (status in ('new','contacted','interested','registered','not_interested'));

create index if not exists provider_leads_status_idx on public.provider_leads (status);
create index if not exists provider_leads_created_idx on public.provider_leads (created_at desc);

alter table public.provider_leads enable row level security;

-- Mirrors the customer waitlist exactly: anyone may express interest (the public
-- form runs on the anon key and the person has no account yet), only an admin can
-- READ them back. Without the admin-only SELECT this would be a scrapeable list
-- of local contractors' names, emails and phone numbers.
drop policy if exists provider_leads_insert on public.provider_leads;
create policy provider_leads_insert on public.provider_leads
  for insert with check (true);

drop policy if exists provider_leads_select on public.provider_leads;
create policy provider_leads_select on public.provider_leads
  for select using (is_admin());

drop policy if exists provider_leads_update on public.provider_leads;
create policy provider_leads_update on public.provider_leads
  for update using (is_admin()) with check (is_admin());

drop policy if exists provider_leads_delete on public.provider_leads;
create policy provider_leads_delete on public.provider_leads
  for delete using (is_admin());

create or replace function public.touch_provider_lead()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_touch_provider_lead on public.provider_leads;
create trigger trg_touch_provider_lead
  before update on public.provider_leads
  for each row execute function public.touch_provider_lead();
