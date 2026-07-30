-- Fire the one-time welcome email when a user CONFIRMS their email address.
--
-- Timing matters: sending at signup races the confirmation email and lands a
-- "welcome, here's how it works" in front of someone who can't log in yet.
-- auth.users.email_confirmed_at going NULL -> NOT NULL is the exact moment the
-- account becomes usable.

alter table public.profiles
  add column if not exists welcome_email_sent_at timestamptz;

comment on column public.profiles.welcome_email_sent_at is
  'Stamped by send-welcome-email. Doubles as the idempotency guard AND the abuse '
  'guard for that function, which is publicly reachable (pg_net cannot present a JWT).';

create or replace function public.on_email_confirmed_send_welcome()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  svc_key text := current_setting('app.service_role_key', true);
begin
  -- Only the null -> not-null transition. Ordinary updates to auth.users (a
  -- password change, a login timestamp) must not re-fire this.
  if new.email_confirmed_at is not null and old.email_confirmed_at is null then
    begin
      perform net.http_post(
        url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/send-welcome-email',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || coalesce(svc_key, '')
        ),
        body := jsonb_build_object('user_id', new.id)
      );
    exception when others then
      -- NEVER let a mail problem block email confirmation. A failed welcome email
      -- is a nuisance; a failed confirmation locks the user out of the account
      -- they just created. Same swallow-and-continue rule as dispatch_jobs().
      null;
    end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_on_email_confirmed_send_welcome on auth.users;
create trigger trg_on_email_confirmed_send_welcome
  after update of email_confirmed_at on auth.users
  for each row execute function public.on_email_confirmed_send_welcome();
