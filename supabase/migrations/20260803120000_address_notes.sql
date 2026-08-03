-- Property notes that OUTLIVE a single job.
--
-- jobs.provider_notes dies with its job. The fifth provider sent to a property
-- re-learns what the first four already knew: the gate code, the dog, the septic
-- lid you must not plow over. That is a safety and a damage-liability problem,
-- not just an inconvenience — and it is the one piece of institutional knowledge
-- a marketplace has that an individual contractor doesn't.
--
-- So notes attach to the ADDRESS, and whoever gets dispatched there next reads
-- them before they arrive.
--
-- ⚠️ CUSTOMERS MUST NEVER READ THESE. Same rule as jobs.provider_notes. A
-- customer owns the address row, so the obvious "you can read notes on your own
-- address" policy would be exactly wrong: these are candid operational notes
-- between providers ("dog is aggressive", "owner argues about the walkway"), and
-- showing them to the homeowner would both chill honest notes and start fights.
-- The SELECT policy below is deliberately provider+admin ONLY, with no
-- customer-ownership branch.

create table if not exists public.address_notes (
  id          uuid primary key default gen_random_uuid(),
  address_id  uuid not null references public.addresses(id) on delete cascade,
  -- Author. Null when written by an admin (or when a provider row is later
  -- deleted) — the note itself must survive, it's about the property.
  provider_id uuid references public.providers(id) on delete set null,
  author_role text not null default 'provider' check (author_role in ('provider','admin')),
  category    text not null check (category in ('safety','access','quirk')),
  note        text not null check (length(btrim(note)) between 1 and 500),
  -- Soft delete: a retracted note stays readable to admin. Providers hide their
  -- own mistakes without destroying a record someone may need after a damage claim.
  archived    boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz
);

create index if not exists address_notes_address_idx
  on public.address_notes (address_id) where archived = false;

-- Has the CALLER ever been the provider on a job at this address (offered,
-- assigned, or completed)? That is the whole read/write gate: you get the
-- property's notes because you have been sent to the property.
create or replace function public.provider_worked_address(addr uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.jobs j
    where j.address_id = addr
      and (j.provider_id in (select public.my_provider_ids())
        or j.dispatched_to in (select public.my_provider_ids()))
  );
$$;
grant execute on function public.provider_worked_address(uuid) to authenticated;

alter table public.address_notes enable row level security;

drop policy if exists address_notes_select on public.address_notes;
create policy address_notes_select on public.address_notes for select to authenticated
using (
  public.is_admin()
  or (not archived and public.provider_worked_address(address_id))
);

drop policy if exists address_notes_insert on public.address_notes;
create policy address_notes_insert on public.address_notes for insert to authenticated
with check (
  public.is_admin()
  or (public.is_approved_provider() and public.provider_worked_address(address_id))
);

-- Edit/retract your own note; admin edits anything.
drop policy if exists address_notes_update on public.address_notes;
create policy address_notes_update on public.address_notes for update to authenticated
using (
  public.is_admin()
  or provider_id in (select public.my_provider_ids())
)
with check (
  public.is_admin()
  or provider_id in (select public.my_provider_ids())
);

-- Hard delete is admin-only; providers archive instead (see `archived`).
drop policy if exists address_notes_delete on public.address_notes;
create policy address_notes_delete on public.address_notes for delete to authenticated
using (public.is_admin());

-- RLS filters what a role may already touch; a fresh table has NO privileges for
-- authenticated, so without these the policies above are unreachable (401 /
-- 42501). Learned the hard way on provider_leads — see 20260731123000.
-- anon gets NOTHING: there is no logged-out path to these notes.
grant select, insert, update on public.address_notes to authenticated;
grant delete on public.address_notes to authenticated; -- gated to admin by RLS
grant all on public.address_notes to service_role;

-- Stamp the author server-side so a provider can't post as someone else, and
-- keep updated_at honest.
create or replace function public.set_address_note_author()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  mine uuid;
begin
  if tg_op = 'INSERT' then
    select id into mine from public.providers where user_id = auth.uid() limit 1;
    if mine is not null then
      new.provider_id := mine;
      new.author_role := 'provider';
    else
      -- No providers row → this is an admin acting from the panel.
      new.provider_id := null;
      new.author_role := 'admin';
    end if;
  else
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_address_note_author on public.address_notes;
create trigger trg_set_address_note_author
  before insert or update on public.address_notes
  for each row execute function public.set_address_note_author();
