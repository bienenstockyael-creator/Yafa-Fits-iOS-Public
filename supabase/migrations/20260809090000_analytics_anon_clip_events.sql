-- The App Clip runs unauthenticated (no accounts, no SDKs), but its
-- funnel events (clip_open, clip_get_tapped, clip_profile_opened)
-- are the top of the install funnel — we need them in
-- analytics_events alongside the app's events.
--
-- Anon inserts are allowed ONLY with a null user_id: an anonymous
-- client can never attribute an event to a real user, and the
-- existing authenticated policy ("analytics_events_insert_own")
-- stays untouched. Table remains write-only from clients — no
-- select/update/delete policies for anon.
--
-- Clip events are distinguishable in queries by user_id is null.

drop policy if exists "analytics_events_insert_anon" on public.analytics_events;
create policy "analytics_events_insert_anon"
    on public.analytics_events
    for insert
    to anon
    with check (user_id is null);
