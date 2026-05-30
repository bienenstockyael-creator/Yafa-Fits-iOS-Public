-- Lightweight analytics events table. Used to track funnel
-- conversion for the contacts-sharing flow (and any future
-- feature where opt-in / drop-off rates matter).
--
-- Each row is one event: who fired it, what it's called, an
-- optional bag of properties as JSON. Query via the Supabase
-- dashboard SQL editor — there's no client read path; this is
-- write-only from the app.
--
-- Example funnel queries:
--   select event_name, count(*) from public.analytics_events
--     where event_name like 'contacts_%'
--     group by event_name
--     order by 2 desc;
--
--   select count(distinct user_id) filter (where event_name = 'contacts_prompt_shown'),
--          count(distinct user_id) filter (where event_name = 'contacts_permission_granted')
--     from public.analytics_events;

create table if not exists public.analytics_events (
    id uuid primary key default gen_random_uuid(),
    user_id uuid references auth.users(id) on delete cascade,
    event_name text not null,
    properties jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

create index if not exists analytics_events_event_name_idx
    on public.analytics_events(event_name, created_at desc);

create index if not exists analytics_events_user_id_idx
    on public.analytics_events(user_id, created_at desc);

alter table public.analytics_events enable row level security;

-- Authenticated users can insert events tagged with their own
-- user_id. They cannot read or update or delete — the events
-- table is write-only from the client.
drop policy if exists "analytics_events_insert_own" on public.analytics_events;
create policy "analytics_events_insert_own"
    on public.analytics_events
    for insert
    to authenticated
    with check (user_id = auth.uid());
