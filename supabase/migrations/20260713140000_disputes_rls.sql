-- The disputes table shipped with RLS enabled but ZERO policies, so it was
-- completely inaccessible (the reason the dispute feature was never usable).
-- These policies make it work with least privilege:
--   * a party to the job (the customer, or the provider on the job) can file one
--   * a reporter can read their own; an admin can read all
--   * only an admin can resolve/update
-- Applied to the linked project 2026-07-13.

-- Reporter (the customer, or the provider on the job) OR an admin can read.
create policy "read own or admin" on public.disputes for select to authenticated
using (
  auth.uid() = customer_id
  or auth.uid() in (select user_id from public.providers where id = disputes.provider_id)
  or coalesce((select is_admin from public.profiles where id = auth.uid()), false)
);

-- A party to the job (customer or provider) can file a dispute.
create policy "party can insert" on public.disputes for insert to authenticated
with check (
  auth.uid() = customer_id
  or auth.uid() in (select user_id from public.providers where id = disputes.provider_id)
);

-- Only an admin can resolve/update a dispute.
create policy "admin can update" on public.disputes for update to authenticated
using (coalesce((select is_admin from public.profiles where id = auth.uid()), false))
with check (coalesce((select is_admin from public.profiles where id = auth.uid()), false));
