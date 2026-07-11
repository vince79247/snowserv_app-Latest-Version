-- One device = one push token = one user. The client saves its FCM token on
-- login/refresh, but clearing that token off OTHER profiles (a previous account
-- on the same phone) can't be done client-side — RLS correctly stops a user
-- from updating someone else's row. This SECURITY DEFINER RPC does the
-- cross-clear + own-save atomically, keyed to the caller's auth.uid(), so a
-- push for an old account never lands on whoever holds the device now.
CREATE OR REPLACE FUNCTION claim_fcm_token(p_token text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR p_token IS NULL OR length(p_token) = 0 THEN
    RETURN; -- anon or empty token: nothing to claim
  END IF;
  UPDATE profiles SET fcm_token = NULL
    WHERE fcm_token = p_token AND id <> auth.uid();
  UPDATE profiles SET fcm_token = p_token
    WHERE id = auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION claim_fcm_token(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION claim_fcm_token(text) TO authenticated;
