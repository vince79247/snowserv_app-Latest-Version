-- Candidate list for the nightly chase-providers cron.
--
-- Lives in SQL rather than the edge function for one reason: it joins
-- auth.users, which PostgREST cannot reach. SECURITY DEFINER so it can.
--
-- It DECIDES NOTHING — it reports state and lets the caller apply the quiet
-- period and contact cap, so those thresholds stay visible in one readable
-- place instead of buried in a migration nobody re-reads.
--
-- Deliberately excluded:
--   • is_test accounts        — not people
--   • suspended users         — we are not chasing somebody we suspended
--   • pending_review          — that needs an ADMIN to act, not an email to the
--                               provider; it belongs in a digest
--   • approved + payouts_enabled — already working; nothing to chase
CREATE OR REPLACE FUNCTION public.providers_needing_nudge()
RETURNS TABLE (
  provider_id uuid,
  name text,
  email text,
  registration_status text,
  payouts_enabled boolean,
  email_confirmed boolean,
  recruit_emailed_at timestamptz,
  created_at timestamptz,
  contacts bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $function$
  SELECT p.id,
         u.name,
         u.email,
         p.registration_status,
         COALESCE(p.payouts_enabled, false),
         (a.email_confirmed_at IS NOT NULL),
         p.recruit_emailed_at,
         p.created_at,
         (SELECT count(*) FROM public.email_log e WHERE e.provider_id = p.id)
    FROM public.providers p
    JOIN public.users u ON u.id = p.user_id
    JOIN auth.users a   ON a.id = p.user_id
   WHERE COALESCE(u.is_test, false) = false
     AND COALESCE(u.is_suspended, false) = false
     AND p.registration_status IN ('incomplete', 'approved')
     AND NOT (p.registration_status = 'approved' AND COALESCE(p.payouts_enabled, false) = true)
   ORDER BY p.created_at;
$function$;

-- Only the server calls this. No grant to anon or authenticated.
REVOKE ALL ON FUNCTION public.providers_needing_nudge() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.providers_needing_nudge() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.providers_needing_nudge() TO service_role;
