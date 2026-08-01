-- URGENT FIX for 20260801120000, which broke signup for every already-shipped
-- client build.
--
-- The bug: v_optin was computed as
--     (new.raw_user_meta_data->>'marketing_opt_in') = 'true'
-- When the key is ABSENT, ->> returns NULL, and `NULL = 'true'` is NULL — not
-- false. SQL three-valued logic. That NULL then hit the NOT NULL column and the
-- whole insert died with 23502, taking the signup with it.
--
-- Every installed build (11/12/13 on Vince's iPhone and Tony's Android) omits
-- this field, so this was not a theoretical edge case — it was a total signup
-- outage for existing app installs the moment the previous migration applied.
-- Caught by testing the "older client" path explicitly rather than only the two
-- happy paths.
--
-- coalesce(..., false) restores the intent: absent or malformed means NO consent.

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
  -- Anything that is not exactly the string 'true' — including a missing key
  -- from an older build — is a NO. Never NULL.
  v_optin boolean := coalesce((new.raw_user_meta_data->>'marketing_opt_in') = 'true', false);
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

-- Belt and braces: even if some other write path forgets the column, a NULL must
-- degrade to "no consent" rather than erroring or, worse, being treated as yes.
alter table public.users alter column marketing_opt_in set default false;
