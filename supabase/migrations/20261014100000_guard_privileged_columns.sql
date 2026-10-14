-- PRIVILEGE ESCALATION FIX — any signed-up user could make themselves admin.
--
-- FOUND 2026-10-14 by Vince: "I just tried my vCitarella username and was able to
-- log into admin... did I just discover a mistake?" He had. Four escalations were
-- confirmed by actually running them against production with a throwaway account
-- and the PUBLIC anon key:
--
--   1. profiles.is_admin            -> true        FULL ADMIN PANEL
--   2. providers.registration_status-> 'approved'  self-approve, get dispatched work
--   3. providers.payouts_enabled    -> true        mark self payable
--   4. users.is_suspended           -> false       un-suspend self
--
-- CAUSE: the RLS UPDATE policies are row-scoped but not COLUMN-scoped —
-- `(id = auth.uid()) OR is_admin()` happily permits a user to rewrite any column
-- on their own row, including the one that grants admin. RLS answers "may you
-- touch this row", never "may you touch this column".
--
-- WHY A TRIGGER RATHER THAN REWRITING THE POLICIES: a BEFORE UPDATE trigger
-- covers every path into the table — today's policies, tomorrow's policies, an
-- RPC someone adds later, a forgotten endpoint. Column rules expressed inside a
-- WITH CHECK have to be re-stated correctly in every policy that ever touches the
-- table, and the first one that forgets re-opens this hole silently.
--
-- IT RESTORES RATHER THAN RAISES, deliberately: a client that PATCHes a whole row
-- back (which several screens do) must not start erroring, and an attacker gets no
-- feedback telling them what the guard is watching.
--
-- WHO BYPASSES: service_role (every edge function — connect-status caches
-- payouts_enabled, the webhook writes jobs, batch-payouts reads), postgres and
-- supabase_admin (migrations, and SECURITY DEFINER RPCs like rate_job and
-- increment_post_start_cancel, which run as their owner), and any real admin.

-- ⚠️ SECURITY INVOKER, NOT DEFINER — THIS IS LOAD-BEARING.
-- The first version of this guard was SECURITY DEFINER and was a complete no-op:
-- inside a DEFINER function `current_user` is the function's OWNER (postgres), so
-- the privileged-role bypass below fired for every caller including attackers.
-- It applied cleanly, looked right, and blocked nothing — caught only by re-running
-- the four attacks against it. As INVOKER, current_user is the caller's real role:
-- 'authenticated' for a logged-in user, 'service_role' for an edge function,
-- 'postgres' for a migration or a SECURITY DEFINER RPC running as its owner.
-- public.is_admin() is itself SECURITY DEFINER, so it still works from here.
CREATE OR REPLACE FUNCTION public.guard_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- Edge functions, migrations and SECURITY DEFINER RPCs run as a privileged
  -- role; a genuine admin passes is_admin(). Everyone else is constrained below.
  IF current_user IN ('service_role', 'postgres', 'supabase_admin')
     OR coalesce(
          current_setting('request.jwt.claims', true)::jsonb ->> 'role', ''
        ) = 'service_role'
     OR coalesce(public.is_admin(), false) THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'profiles' THEN
    -- There is no legitimate client write to is_admin anywhere in lib/.
    NEW.is_admin := OLD.is_admin;
    -- ⚠️ role IS A SECOND DOOR. main.dart's RoleRouter reads
    --   `if (isAdmin || role == 'admin') return const AdminPanelScreen();`
    -- so setting role='admin' routes a user straight to the admin screen even
    -- with is_admin false. RLS still starved it of data (the attacker saw 1 of 20
    -- users and 0 of 7 jobs), so it was a UI bypass rather than a breach — but it
    -- is one RLS slip away from being real. role is only ever written at SIGNUP,
    -- which is an INSERT, and this trigger is UPDATE-only, so freezing it here
    -- costs nothing. Found 2026-10-14 immediately after the is_admin fix, by
    -- reading what else the router trusts.
    NEW.role := OLD.role;

  ELSIF TG_TABLE_NAME = 'providers' THEN
    -- A provider MAY submit their own application (provider_registration_screen
    -- writes 'pending_review'). They may not approve or reject it.
    IF NEW.registration_status IS DISTINCT FROM OLD.registration_status
       AND NEW.registration_status <> 'pending_review' THEN
      NEW.registration_status := OLD.registration_status;
    END IF;
    NEW.payouts_enabled             := OLD.payouts_enabled;   -- only connect-status
    NEW.stripe_connect_id           := OLD.stripe_connect_id; -- only connect-onboard
    NEW.is_verified                 := OLD.is_verified;
    NEW.rating                      := OLD.rating;            -- only rate_job RPC
    NEW.total_jobs                  := OLD.total_jobs;
    NEW.provider_number             := OLD.provider_number;
    NEW.preferred_until             := OLD.preferred_until;   -- admin-only lever
    NEW.review_note                 := OLD.review_note;
    NEW.cancelled_after_start_count := OLD.cancelled_after_start_count;

  ELSIF TG_TABLE_NAME = 'users' THEN
    NEW.is_suspended  := OLD.is_suspended;
    NEW.is_flagged    := OLD.is_flagged;
    NEW.is_test       := OLD.is_test;
    NEW.dispute_count := OLD.dispute_count;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_privileged_profiles ON public.profiles;
CREATE TRIGGER guard_privileged_profiles
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_privileged_columns();

DROP TRIGGER IF EXISTS guard_privileged_providers ON public.providers;
CREATE TRIGGER guard_privileged_providers
  BEFORE UPDATE ON public.providers
  FOR EACH ROW EXECUTE FUNCTION public.guard_privileged_columns();

DROP TRIGGER IF EXISTS guard_privileged_users ON public.users;
CREATE TRIGGER guard_privileged_users
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.guard_privileged_columns();
