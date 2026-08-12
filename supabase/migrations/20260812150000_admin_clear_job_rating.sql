-- Let an admin remove a rating that was demonstrably unfair.
--
-- WHY: build 23 ships copy in the provider rating guide telling providers
-- "if you think a rating was unfair, email us — we'd rather hear about it than
-- have you assume the number is stuck." Nothing backed that. The admin panel
-- could display a rating and nothing else.
--
-- REMOVE, NOT REWRITE. There is deliberately no "change it to 5 stars": editing
-- what a customer said into a different number is falsifying their review.
-- Dropping a bad-faith rating out of the average is defensible; inventing a
-- replacement is not.
--
-- THE TRAP THIS AVOIDS: you cannot fix an unfair rating by updating
-- providers.rating directly. rate_job() recomputes that column as the average of
-- jobs.customer_rating every time ANY customer rates ANY job for that provider,
-- so a manual override survives only until the provider's next rating and then
-- vanishes with no trace. The fix has to change the JOB row and recompute, which
-- is exactly what this does.

alter table public.jobs add column if not exists rating_removed_stars  int;
alter table public.jobs add column if not exists rating_removed_reason text;
alter table public.jobs add column if not exists rating_removed_at     timestamptz;

comment on column public.jobs.rating_removed_stars is
  'What the customer originally gave, kept after an admin removed it from the average.';

create or replace function public.admin_clear_job_rating(p_job_id uuid, p_reason text default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider uuid;
  v_avg numeric;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;

  -- Preserve the original stars and the reason. A rating that silently
  -- disappears is impossible to explain to the customer who left it, or to the
  -- provider six months later asking why their average moved.
  update public.jobs
     set rating_removed_stars  = customer_rating,
         rating_removed_reason = nullif(btrim(coalesce(p_reason, '')), ''),
         rating_removed_at     = now(),
         customer_rating       = null
   where id = p_job_id
     and customer_rating is not null
  returning provider_id into v_provider;

  if not found then
    raise exception 'that job has no rating to remove';
  end if;

  -- Same averaging rate_job() uses, so the two can never disagree.
  if v_provider is not null then
    select round(avg(customer_rating)::numeric, 1) into v_avg
      from public.jobs
     where provider_id = v_provider
       and customer_rating is not null;
    -- NULL when that was their only rating: back to genuinely unrated, which
    -- dispatch treats as 5.0 via COALESCE(rating, 5) — the same standing a brand
    -- new provider has, not a penalty.
    update public.providers set rating = v_avg where id = v_provider;
  end if;

  return v_avg;
end $$;

revoke all on function public.admin_clear_job_rating(uuid, text) from public, anon;
grant execute on function public.admin_clear_job_rating(uuid, text) to authenticated;
