-- Why people delete their accounts.
--
-- Vince asked for this while testing: the Delete Account row sits in the same
-- menu as Log Out, and he wanted both a stronger deliberate step and a reason
-- to learn something from a departure instead of just losing the person.
--
-- Deliberately holds NO identifying data — no user id, no email, no name. The
-- user just asked to be erased; recording who complained about what would
-- defeat the request and the deletion function's whole purpose. Role, reason
-- and an optional free note are enough to spot a pattern.
create table if not exists public.account_deletion_feedback (
  id uuid primary key default gen_random_uuid(),
  role text,
  reason text,
  note text,
  created_at timestamptz not null default now()
);

comment on table public.account_deletion_feedback is
  'Why people delete their accounts. Deliberately holds NO identifying data - no user id, email or name - because the whole point of the request was to erase them. Role + reason + free note only.';

alter table public.account_deletion_feedback enable row level security;

-- Written while the user is still signed in, immediately before deletion.
drop policy if exists adf_insert on public.account_deletion_feedback;
create policy adf_insert on public.account_deletion_feedback
  for insert to authenticated with check (true);

drop policy if exists adf_select on public.account_deletion_feedback;
create policy adf_select on public.account_deletion_feedback
  for select using (is_admin());
