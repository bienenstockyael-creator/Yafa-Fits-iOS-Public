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
