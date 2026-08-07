-- One record of every email SnowServ sends to a person.
--
-- Vince emailed two customers from the admin panel and had nothing afterwards
-- to show it happened — the snackbar is gone in four seconds. This has bitten
-- three times now in different clothes: he went looking in Zoho's Sent folder
-- for mail Resend had sent (Zoho never touched it), he emailed Scott twice
-- because the first send left no trace, and he could not tell whether Rosa had
-- been contacted. Each time the fix was another one-off boolean on another
-- table. This replaces that pattern with the general answer.
--
-- Deliberately ONE table for every sender (send-admin-email, send-lead-email,
-- and anything we add later), keyed loosely by whichever id applies, so
-- "everything we have ever said to this person" is a single query no matter
-- which side of the marketplace they are on.
--
-- The BODY is kept. Re-reading what you actually told someone is most of the
-- value — "what did I promise this guy?" is the question you ask three weeks
-- later. It is our own outbound content and admin-only under RLS.
--
-- Forward-looking: an AI support agent answering support@ needs exactly this
-- as context. Storing it now costs nothing and means the history already
-- exists when that gets built, instead of starting from empty.

create table if not exists public.email_log (
  id uuid primary key default gen_random_uuid(),
  to_email text not null,
  subject text,
  body text,
  -- Whichever of these applies; all nullable. A person can be a user and a
  -- provider at once, so this is not an either/or.
  user_id uuid,
  lead_id uuid,
  provider_id uuid,
  -- Which message went out: 'admin_freeform', 'lead_new', 'stalled_signup',
  -- 'pending_review', 'out_of_area'.
  template text,
  sent_by uuid,          -- the admin who sent it (null for automated sends)
  created_at timestamptz not null default now()
);

comment on table public.email_log is
  'Every email SnowServ sends a person, from any function. Admin-readable history so a send is never invisible and so support context survives the session.';

create index if not exists email_log_user_idx on public.email_log (user_id, created_at desc);
create index if not exists email_log_lead_idx on public.email_log (lead_id, created_at desc);
create index if not exists email_log_provider_idx on public.email_log (provider_id, created_at desc);
create index if not exists email_log_created_idx on public.email_log (created_at desc);

alter table public.email_log enable row level security;

-- Read: admins only. It contains recipients' addresses and the full text of
-- what we said to them.
drop policy if exists email_log_select on public.email_log;
create policy email_log_select on public.email_log
  for select using (is_admin());

-- No INSERT policy on purpose. Rows are written by the edge functions with the
-- service role (which bypasses RLS), AFTER the mail provider confirms the send.
-- A client that could insert here could fake a delivery record.
