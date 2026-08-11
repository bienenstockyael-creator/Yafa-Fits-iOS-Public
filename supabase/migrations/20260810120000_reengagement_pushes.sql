-- Re-engagement pushes: nudge members who haven't logged a fit in a
-- while. The generation worker (the one service with working APNs
-- credentials) polls users_needing_reengagement() hourly and sends
-- "log today's fit" pushes; this table is the send log that enforces
-- the cooldown so nobody gets nagged.
--
-- Service-role only: no client policies on purpose — the app never
-- reads or writes this.

create table if not exists public.reengagement_pushes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_sent_at timestamptz not null default now()
);

alter table public.reengagement_pushes enable row level security;

-- Eligibility: onboarded, has a push token, no fit logged in
-- `days_inactive` days (never-posted users count from signup), and
-- not reminded within `cooldown_days`. Capped so one worker tick
-- can't blast the whole userbase at once.
create or replace function public.users_needing_reengagement(
  days_inactive int default 7,
  cooldown_days int default 14,
  max_rows int default 50
)
returns table(user_id uuid)
language sql
security definer
set search_path = public
as $func$
  select p.id
  from public.profiles p
  where p.is_onboarded
    and exists (
      select 1 from public.device_push_tokens t where t.user_id = p.id
    )
    and coalesce(
      (select max(o.created_at) from public.outfits o where o.user_id = p.id),
      p.created_at
    ) < now() - make_interval(days => days_inactive)
    and not exists (
      select 1 from public.reengagement_pushes r
      where r.user_id = p.id
        and r.last_sent_at > now() - make_interval(days => cooldown_days)
    )
  limit max_rows;
$func$;

revoke execute on function public.users_needing_reengagement(int, int, int) from public, anon, authenticated;
grant execute on function public.users_needing_reengagement(int, int, int) to service_role;
