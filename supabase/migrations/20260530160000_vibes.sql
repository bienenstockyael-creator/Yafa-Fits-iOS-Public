-- Vibes: a scarce reaction system. Each user gets 3 vibes per
-- ISO week (Monday 00:00 UTC reset). Vibes are given on
-- specific outfits and accrue on the recipient's profile.
-- Every 5 vibes received unlocks a free 3D generation
-- (reward integration lives in a later migration).
--
-- Schema rules:
--   * One vibe per (giver, outfit) — can't double-vibe
--   * Self-vibing blocked at the RPC layer
--   * Once given, vibes are final (no take-back)
--   * Quota window keyed by ISO week (IYYY-"W"IW) computed in
--     UTC, so all clients agree on the boundary

create table if not exists public.vibes (
    id uuid primary key default gen_random_uuid(),
    giver_id uuid not null references auth.users(id) on delete cascade,
    receiver_id uuid not null references public.profiles(id) on delete cascade,
    outfit_id text not null references public.outfits(id) on delete cascade,
    iso_week text not null,
    created_at timestamptz not null default now(),
    -- Hard prevention of double-vibing. The RPC ALSO checks
    -- this to return a friendlier error code, but the
    -- constraint is the source of truth.
    unique (giver_id, outfit_id)
);

create index if not exists vibes_giver_week_idx
    on public.vibes(giver_id, iso_week);
create index if not exists vibes_receiver_idx
    on public.vibes(receiver_id, created_at desc);
create index if not exists vibes_outfit_idx
    on public.vibes(outfit_id, created_at desc);

alter table public.vibes enable row level security;

-- Readable by any authenticated user so we can render vibers
-- lists and outfit vibe counts.
drop policy if exists "vibes_read_all" on public.vibes;
create policy "vibes_read_all"
    on public.vibes
    for select
    to authenticated
    using (true);

-- Inserts go exclusively through the give_vibe RPC (SECURITY
-- DEFINER), so we don't grant direct INSERT on the table.

-- ============================================================
-- RPC: give_vibe(outfit_id)
-- Atomically: check weekly quota, prevent self/double-vibe,
-- insert. Returns success flag, remaining quota for the week,
-- and a string error_code on failure for client-side messaging.
-- ============================================================
create or replace function public.give_vibe(
    p_outfit_id text
)
returns table (
    success boolean,
    remaining_this_week int,
    error_code text
)
language plpgsql
security definer
set search_path = public
as $func$
declare
    v_giver uuid := auth.uid();
    v_receiver uuid;
    v_iso_week text := to_char(now() at time zone 'UTC', 'IYYY-"W"IW');
    v_weekly_quota constant int := 3;
    v_given_this_week int;
begin
    if v_giver is null then
        return query select false, 0, 'unauthenticated'::text;
        return;
    end if;

    -- Per-user advisory lock so concurrent give_vibe calls from
    -- the same user serialize. Without this, two simultaneous
    -- taps on different outfits could both pass the quota check
    -- and let the user exceed their 3/week limit.
    perform pg_advisory_xact_lock(hashtext('vibes:' || v_giver::text));

    select user_id into v_receiver
    from public.outfits
    where id = p_outfit_id;

    if v_receiver is null then
        return query select false, 0, 'outfit_not_found'::text;
        return;
    end if;

    if v_receiver = v_giver then
        return query select false, 0, 'self_vibe'::text;
        return;
    end if;

    select count(*) into v_given_this_week
    from public.vibes
    where giver_id = v_giver and iso_week = v_iso_week;

    if v_given_this_week >= v_weekly_quota then
        return query select false, 0, 'quota_exhausted'::text;
        return;
    end if;

    -- The unique(giver_id, outfit_id) constraint guards
    -- double-vibing at the DB level. We catch and report as
    -- `already_vibed` so the client can surface a clear msg.
    begin
        insert into public.vibes (
            giver_id, receiver_id, outfit_id, iso_week
        ) values (
            v_giver, v_receiver, p_outfit_id, v_iso_week
        );
    exception when unique_violation then
        return query select
            false,
            (v_weekly_quota - v_given_this_week)::int,
            'already_vibed'::text;
        return;
    end;

    return query select
        true,
        (v_weekly_quota - v_given_this_week - 1)::int,
        null::text;
end;
$func$;

grant execute on function public.give_vibe(text) to authenticated;

-- ============================================================
-- RPC: vibes_remaining_this_week()
-- Cheap read for the UI to know how many vibes the user has
-- left without making them tap to find out.
-- ============================================================
create or replace function public.vibes_remaining_this_week()
returns int
language sql
security definer
set search_path = public
stable
as $func$
    select greatest(
        0,
        3 - count(*)
    )::int
    from public.vibes
    where giver_id = auth.uid()
      and iso_week = to_char(now() at time zone 'UTC', 'IYYY-"W"IW');
$func$;

grant execute on function public.vibes_remaining_this_week()
    to authenticated;

-- ============================================================
-- RPC: vibes_received_count(p_user_id)
-- Total all-time vibes received by a user. Drives the profile
-- stats row.
-- ============================================================
create or replace function public.vibes_received_count(
    p_user_id uuid
)
returns int
language sql
security definer
set search_path = public
stable
as $func$
    select count(*)::int
    from public.vibes
    where receiver_id = p_user_id;
$func$;

grant execute on function public.vibes_received_count(uuid)
    to authenticated;
