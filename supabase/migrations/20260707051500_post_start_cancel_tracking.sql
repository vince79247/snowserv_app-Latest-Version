-- Post-start cancel accountability (decided 2026-07-07 with Vince).
--
-- Policy: a provider cancelling AFTER starting a job (i.e. after the payment
-- hold was captured) keeps the charge in place and the job re-dispatches to the
-- next provider — capture-payment is idempotent so the second Start never
-- double-charges. But because Start is what triggers the charge, bailing after
-- start is the most abusable provider move, so we count it per provider for
-- admin visibility (repeat offenders show in the admin panel).

ALTER TABLE providers
  ADD COLUMN IF NOT EXISTS cancelled_after_start_count integer NOT NULL DEFAULT 0;

-- Atomic increment, callable from the provider app. SECURITY DEFINER so it works
-- regardless of RLS on providers, but scoped so a caller can only bump the
-- counter on their OWN provider row (user_id must match the auth token).
CREATE OR REPLACE FUNCTION increment_post_start_cancel(p_provider_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE providers
  SET cancelled_after_start_count = cancelled_after_start_count + 1
  WHERE id = p_provider_id
    AND user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION increment_post_start_cancel(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION increment_post_start_cancel(uuid) TO authenticated;
