-- Backfill provider_leads.contacted_at from the real send record.
--
-- THE BUG (found 2026-10-15 by Vince, looking at Muhammad's card):
-- contacted_at had TWO writers and only one of them stamped the date.
--   * admin panel _setLeadStatus()  -> writes status AND contacted_at  ✓
--   * send-lead-email (server)      -> wrote status ALONE              ✗
-- So any lead contacted by the nightly chaser went to status='contacted'
-- with contacted_at still NULL. Six of nine rows were in that state.
--
-- Why it matters rather than being cosmetic: the admin lead card shows
-- "Emailed <date>" from email_log, and falls back to "Contacted <date>" from
-- contacted_at when email_log has nothing. That fallback exists for leads
-- contacted before email_log existed (Aug 7 2026). With contacted_at null the
-- fallback has nothing to show, so such a lead reads as never-contacted.
--
-- The function is fixed to stamp it going forward. This repairs the existing
-- rows from email_log, which is the authoritative record of every send.
-- FIRST contact wins (min), matching the rule in both writers: the question is
-- "when did we first reach out", not "when did we last touch the row".

update public.provider_leads l
set contacted_at = e.first_sent
from (
  select lead_id, min(created_at) as first_sent
  from public.email_log
  where lead_id is not null
  group by lead_id
) e
where e.lead_id = l.id
  and l.contacted_at is null;
