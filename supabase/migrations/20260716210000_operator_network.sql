-- Commercial & Emergency Response Network — passive operator lead capture.
-- Heavy-equipment operators (plow trucks, loaders, triaxle dumps) opt into a
-- standby list from the marketing website. Phase-2 groundwork (see ROADMAP.md):
-- build the supply-side database now so the network moat compounds before launch.
--
-- Security mirrors `waitlist`: ANYONE may submit (public form, anon key), but the
-- collected leads are PRIVATE — only admins can read them (never exposed publicly).

create table if not exists public.operator_network (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  name           text,
  company        text,
  email          text,
  phone          text,
  equipment      text,        -- primary equipment type (select on the form)
  fleet          text,        -- free text: "2 triaxles + 1 loader"
  base_zip       text,
  service_radius text,        -- how far they'll travel
  insured        boolean,
  dot_number     text,
  notes          text
);

alter table public.operator_network enable row level security;

-- Public may INSERT an application (anon key from the website form)...
drop policy if exists operator_network_insert on public.operator_network;
create policy operator_network_insert on public.operator_network
  for insert to anon, authenticated
  with check (true);

-- ...but only admins may READ the collected leads.
drop policy if exists operator_network_admin_select on public.operator_network;
create policy operator_network_admin_select on public.operator_network
  for select to authenticated
  using (public.is_admin());

grant insert on public.operator_network to anon, authenticated;
grant select on public.operator_network to authenticated;
