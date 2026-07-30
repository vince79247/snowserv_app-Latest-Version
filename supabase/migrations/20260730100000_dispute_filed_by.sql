-- Records WHICH SIDE filed a dispute: 'customer' or 'provider'.
--
-- Why: resolving a dispute in the admin panel wrote the row and told nobody.
-- Vince hit this live on 2026-07-29 ("I just rejected Tony's dispute. Will he
-- be notified?" — no, he wasn't). We can't fix that without knowing who to
-- notify: both parties are on every dispute row, and guessing "the customer"
-- would push a resolution to the wrong person every time a PROVIDER reported
-- the problem (provider-filed reasons like "Could not access the property"
-- exist in the filing UI).

alter table public.disputes
  add column if not exists filed_by text;

alter table public.disputes
  drop constraint if exists disputes_filed_by_check;
alter table public.disputes
  add constraint disputes_filed_by_check
  check (filed_by is null or filed_by in ('customer', 'provider'));

-- Derive it from the CALLER instead of trusting the client. The INSERT policy
-- ("party can insert") already proves the caller is one of the two parties, so
-- auth.uid() tells us which side they are. A lying client could otherwise
-- misroute its own resolution push, and would poison the column for any future
-- "who complains more" reporting. Service-role inserts have no auth.uid() and
-- keep whatever was passed in.
create or replace function public.set_dispute_filed_by()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return new;
  end if;
  if auth.uid() = new.customer_id then
    new.filed_by := 'customer';
  elsif exists (
    select 1 from public.providers p
    where p.id = new.provider_id and p.user_id = auth.uid()
  ) then
    new.filed_by := 'provider';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_dispute_filed_by on public.disputes;
create trigger trg_set_dispute_filed_by
  before insert on public.disputes
  for each row execute function public.set_dispute_filed_by();

-- Backfill. Exactly one dispute predates this column (the 2026-07-29 test one).
-- Verified, not assumed: its filer has no row in providers at all, so the
-- customer side is the only side they could have filed from.
update public.disputes set filed_by = 'customer' where filed_by is null;
