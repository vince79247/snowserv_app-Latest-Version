-- Put provider_leads on the realtime publication.
--
-- The admin panel subscribes to a channel for live refresh, but a Postgres
-- table emits nothing unless it is also a member of the `supabase_realtime`
-- publication. provider_leads was in neither the subscription nor the 60-second
-- safety poll, so a website lead stayed invisible until somebody reopened the
-- panel. Vince hit it 2026-10-15 — a lead sat "awaiting follow-up" and the only
-- way to see it was a manual refresh.
--
-- Website leads are the one thing that arrives with nobody watching, which makes
-- them the worst thing to miss.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
     WHERE pubname = 'supabase_realtime' AND tablename = 'provider_leads'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.provider_leads;
  END IF;
END $$;
