-- ════════════════════════════════════════════════════════════════
-- YAFA METRICS DASHBOARD
-- Paste any block into the Supabase SQL editor (each block is
-- standalone). Save the ones you use as snippets for one-click
-- reruns. All time windows are easy to tweak — look for the
-- `interval` literals.
-- ════════════════════════════════════════════════════════════════


-- ── 1. DAILY ACTIVE USERS (last 14 days) ─────────────────────────
-- "Active" = did anything social or creative that day. Unions the
-- activity tables since client events are sparse pre-1.2.3.
with activity as (
  select user_id, created_at from public.likes
  union all
  select user_id, created_at from public.comments
  union all
  select giver_id, created_at from public.vibes
  union all
  select follower_id, created_at from public.follows
  union all
  select user_id, created_at from public.analytics_events where user_id is not null
)
select
  date_trunc('day', created_at)::date as day,
  count(distinct user_id)             as dau
from activity
where created_at > now() - interval '14 days'
group by 1
order by 1 desc;


-- ── 2. SIGNUPS PER DAY (last 30 days) ────────────────────────────
select
  date_trunc('day', created_at)::date as day,
  count(*)                            as new_users
from auth.users
where created_at > now() - interval '30 days'
group by 1
order by 1 desc;


-- ── 3. CONTENT: OUTFITS LOGGED + PUBLISHED PER DAY ───────────────
select
  date_trunc('day', created_at)::date          as day,
  count(*)                                     as outfits_logged,
  count(*) filter (where is_public)            as published,
  count(*) filter (where frame_count > 1)      as with_3d
from public.outfits
where created_at > now() - interval '14 days'
group by 1
order by 1 desc;


-- ── 4. SOCIAL PULSE PER DAY (last 14 days) ───────────────────────
select day, sum(likes) as likes, sum(comments) as comments,
       sum(vibes) as vibes, sum(follows) as follows
from (
  select date_trunc('day', created_at)::date as day, count(*) as likes, 0 as comments, 0 as vibes, 0 as follows
    from public.likes where created_at > now() - interval '14 days' group by 1
  union all
  select date_trunc('day', created_at)::date, 0, count(*), 0, 0
    from public.comments where created_at > now() - interval '14 days' group by 1
  union all
  select date_trunc('day', created_at)::date, 0, 0, count(*), 0
    from public.vibes where created_at > now() - interval '14 days' group by 1
  union all
  select date_trunc('day', created_at)::date, 0, 0, 0, count(*)
    from public.follows where created_at > now() - interval '14 days' group by 1
) t
group by day
order by day desc;


-- ── 5. INVITE FUNNEL ─────────────────────────────────────────────
-- Codes redeemed per day + who's bringing people in.
select
  date_trunc('day', redeemed_at)::date as day,
  count(*)                             as codes_redeemed
from public.access_codes
where redeemed_at is not null
  and redeemed_at > now() - interval '30 days'
group by 1
order by 1 desc;

-- Top inviters (all time)
select p.username, count(*) as invited
from public.access_codes c
join public.profiles p on p.id = c.inviter_id
where c.redeemed_at is not null
group by 1
order by 2 desc
limit 20;


-- ── 6. GENERATION HEALTH (needs fal-proxy deploy) ────────────────
-- Submissions per day, error rate, and submit latency percentiles.
-- Each fal_submit on the Kling model ≈ money spent.
select
  date_trunc('day', created_at)::date                             as day,
  count(*) filter (where event_name = 'fal_submit')               as submissions,
  count(*) filter (where event_name = 'fal_error')                as errors,
  round(
    100.0 * count(*) filter (where event_name = 'fal_error')
    / greatest(count(*), 1), 1)                                   as error_pct,
  percentile_cont(0.5) within group
    (order by (properties->>'duration_ms')::numeric)              as p50_ms,
  percentile_cont(0.95) within group
    (order by (properties->>'duration_ms')::numeric)              as p95_ms
from public.analytics_events
where event_name in ('fal_submit', 'fal_error', 'fal_proxy_unreachable')
  and created_at > now() - interval '14 days'
group by 1
order by 1 desc;

-- Per-model breakdown (last 7 days) — which endpoints burn money.
select
  properties->>'model'                              as model,
  count(*) filter (where event_name = 'fal_submit') as submissions,
  count(*) filter (where event_name = 'fal_error')  as errors
from public.analytics_events
where event_name in ('fal_submit', 'fal_error')
  and created_at > now() - interval '7 days'
group by 1
order by 2 desc;

-- Estimated FAL spend per day (last 14 days).
-- Kling 10s = $0.72/submit incl. Bria; nano-banana edit ≈ $0.039;
-- adjust constants when pricing/duration changes.
select
  date_trunc('day', created_at)::date as day,
  round(sum(case
    when properties->>'model' like '%kling-video%' then 0.72
    when properties->>'model' like '%nano-banana%' then 0.039
    when properties->>'model' like '%bria%'        then 0.018
    when properties->>'model' like '%sam2%'        then 0.01
    else 0.02
  end)::numeric, 2) as est_spend_usd
from public.analytics_events
where event_name = 'fal_submit'
  and created_at > now() - interval '14 days'
group by 1
order by 1 desc;

-- Top spenders (last 30 days) — who's consuming generations.
select p.username,
       count(*) filter (where e.properties->>'model' like '%kling-video%') as kling_gens
from public.analytics_events e
join public.profiles p on p.id = e.user_id
where e.event_name = 'fal_submit'
  and e.created_at > now() - interval '30 days'
group by 1
order by 2 desc
limit 20;


-- ── 7. APP-EVENT FUNNELS (existing client events) ────────────────
select
  event_name,
  count(*)                 as events,
  count(distinct user_id)  as users
from public.analytics_events
where created_at > now() - interval '14 days'
  and event_name not like 'fal_%'
group by 1
order by 2 desc;


-- ── 8. RETENTION SNAPSHOT ────────────────────────────────────────
-- Of users who signed up 7-14 days ago, how many were active in
-- the last 7 days?
with cohort as (
  select id from auth.users
  where created_at between now() - interval '14 days'
                       and now() - interval '7 days'
),
recent as (
  select distinct user_id from (
    select user_id, created_at from public.likes
    union all select user_id, created_at from public.comments
    union all select giver_id, created_at from public.vibes
    union all select user_id, created_at from public.outfits
  ) a
  where created_at > now() - interval '7 days'
)
select
  (select count(*) from cohort)                                   as cohort_size,
  (select count(*) from cohort c join recent r on r.user_id = c.id) as returned,
  round(100.0 * (select count(*) from cohort c join recent r on r.user_id = c.id)
    / greatest((select count(*) from cohort), 1), 1)              as retention_pct;


-- ── 9. UPLOADERS & FREQUENCY ─────────────────────────────────────
-- Who is actually logging fits, and how often. "Uploader" = created
-- at least one outfit in the window.
select
  count(distinct user_id)                            as uploaders_30d,
  round(count(*)::numeric
    / greatest(count(distinct user_id), 1), 1)       as fits_per_uploader_30d,
  count(*)                                           as fits_30d
from public.outfits
where created_at > now() - interval '30 days';

-- Frequency buckets, last 30 days (how the community splits).
with per_user as (
  select user_id, count(*) as fits
  from public.outfits
  where created_at > now() - interval '30 days'
  group by 1
)
select
  case
    when fits >= 15 then 'near-daily (15+)'
    when fits >= 4  then 'weekly-ish (4-14)'
    else                 'dabbling (1-3)'
  end        as bucket,
  count(*)   as users,
  sum(fits)  as fits
from per_user
group by 1 order by min(fits) desc;

-- Weekly trend: active uploaders + fits per week.
select
  date_trunc('week', created_at)::date as week,
  count(distinct user_id)              as uploaders,
  count(*)                             as fits
from public.outfits
where created_at > now() - interval '10 weeks'
group by 1 order by 1 desc;


-- ── 10. PRIVATE vs PUBLIC + 2D vs 3D ─────────────────────────────
-- Content mix: how much of the archive is shared, and how much gets
-- the full 3D spin (frame_count > 1) vs stays a 2D still.
select
  count(*)                                                        as total_fits,
  count(*) filter (where is_public)                               as public_fits,
  round(100.0 * count(*) filter (where is_public) / greatest(count(*), 1), 1) as public_pct,
  count(*) filter (where frame_count > 1)                         as fits_3d,
  count(*) filter (where frame_count = 1)                         as fits_2d,
  round(100.0 * count(*) filter (where frame_count > 1) / greatest(count(*), 1), 1) as pct_3d
from public.outfits;

-- Same mix, weekly trend.
select
  date_trunc('week', created_at)::date                as week,
  count(*)                                            as fits,
  round(100.0 * count(*) filter (where is_public) / greatest(count(*), 1), 1)      as public_pct,
  round(100.0 * count(*) filter (where frame_count > 1) / greatest(count(*), 1), 1) as pct_3d
from public.outfits
where created_at > now() - interval '10 weeks'
group by 1 order by 1 desc;


-- ── 11. REVENUE (IAP credit packs) ───────────────────────────────
-- Real revenue only: excludes sandbox-environment receipts (stored
-- when ALLOW_SANDBOX_GRANTS was enabled for testing) and the
-- founder's own account (@yafa's TestFlight purchases).
select
  count(distinct user_id)                     as paying_users,
  count(*)                                    as purchases,
  sum(credits_granted)                        as credits_sold,
  round(sum(price_cents) / 100.0, 2)          as gross_usd
from public.credit_purchases
where coalesce(receipt_payload->>'environment', 'Production') <> 'Sandbox'
  and user_id <> '31c9f3fd-e672-43f2-954a-0b141640e76f';  -- @yafa (founder)

-- By package.
select
  product_id,
  count(*)                                    as purchases,
  count(distinct user_id)                     as buyers,
  round(sum(price_cents) / 100.0, 2)          as gross_usd
from public.credit_purchases
where coalesce(receipt_payload->>'environment', 'Production') <> 'Sandbox'
  and user_id <> '31c9f3fd-e672-43f2-954a-0b141640e76f'   -- @yafa (founder)
group by 1 order by gross_usd desc nulls last;

-- By buyer (usernames), same exclusions.
select
  p.username,
  count(*)                                     as purchases,
  string_agg(distinct replace(c.product_id, 'com.yafa.credits.', ''), ', ') as packs,
  sum(c.credits_granted)                       as credits,
  round(sum(c.price_cents) / 100.0, 2)         as spent_usd,
  max(c.created_at)::date                      as last_purchase
from public.credit_purchases c
join public.profiles p on p.id = c.user_id
where coalesce(c.receipt_payload->>'environment', 'Production') <> 'Sandbox'
  and c.user_id <> '31c9f3fd-e672-43f2-954a-0b141640e76f'
group by p.username
order by spent_usd desc;


-- ── 12. INACTIVITY COHORTS ───────────────────────────────────────
-- Days since each member's last fit — the re-engagement push targets
-- the 7+ groups (see users_needing_reengagement()).
with last_fit as (
  select p.id, p.username,
         coalesce(max(o.created_at), p.created_at) as last_activity
  from public.profiles p
  left join public.outfits o on o.user_id = p.id
  where p.is_onboarded
  group by p.id, p.username
)
select
  case
    when last_activity > now() - interval '3 days'  then 'active (0-3d)'
    when last_activity > now() - interval '7 days'  then 'cooling (4-7d)'
    when last_activity > now() - interval '14 days' then 'lapsing (8-14d)'
    else                                                 'dormant (15d+)'
  end      as cohort,
  count(*) as users
from last_fit
group by 1 order by min(now() - last_activity);
