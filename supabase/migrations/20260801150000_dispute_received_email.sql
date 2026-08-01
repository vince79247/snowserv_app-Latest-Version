-- Acknowledge a filed dispute by email.
--
-- Before this, filing a report showed a snackbar that vanished and left the
-- person with no record it landed. That produces exactly the behaviour you don't
-- want: re-filing the same complaint, or emailing support to ask whether anyone
-- saw it.
--
-- Fired from a TRIGGER rather than the client so the acknowledgement can't be
-- lost to a closed app or a dropped connection right after the insert — the same
-- reasoning as the welcome email. Reference is jobs.job_number, which is already
-- unique and already on their receipt; inventing a ticket number would give one
-- problem two IDs.

create or replace function public.on_dispute_filed_send_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  svc_key text := current_setting('app.service_role_key', true);
begin
  begin
    perform net.http_post(
      url := 'https://swttuujhcgpcsrxgupzv.supabase.co/functions/v1/send-dispute-email',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || coalesce(svc_key, '')
      ),
      body := jsonb_build_object('dispute_id', new.id, 'kind', 'received')
    );
  exception when others then
    -- A mail failure must NEVER roll back the dispute itself. Losing the
    -- acknowledgement is an annoyance; losing the complaint is the whole problem
    -- the feature exists to solve.
    null;
  end;
  return new;
end;
$$;

drop trigger if exists trg_on_dispute_filed_send_email on public.disputes;
create trigger trg_on_dispute_filed_send_email
  after insert on public.disputes
  for each row execute function public.on_dispute_filed_send_email();
