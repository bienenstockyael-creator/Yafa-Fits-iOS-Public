-- Lock down phone_e164_hash so it stops being readable by every
-- authenticated user via `select * from profiles`.
--
-- Background: the original `match_contacts_by_phone` RPC stores
-- a SHA-256 of each user's normalized phone number in
-- `profiles.phone_e164_hash`, with `profiles` having a wide-open
-- "Public profiles are viewable by everyone" SELECT policy. SHA-256
-- over the US phone space (~10^11 entries) is brute-forceable on
-- a GPU in hours — so any tester could scrape every hash and
-- recover phone numbers. This migration removes that exposure.
--
-- Three changes:
--   1. Add a server-maintained `phone_is_set boolean` GENERATED
--      column so the iOS app can still gate "ask user for phone"
--      UX without reading the actual hash.
--   2. REVOKE column-level SELECT on `phone_e164_hash` from the
--      `authenticated` and `anon` roles. INSERT/UPDATE column
--      grants are separate, so the existing write path
--      (`SocialService.updatePhoneHash`) keeps working.
--   3. Recreate `match_contacts_by_phone` so it returns an
--      explicit column list that excludes the hash. The
--      previous version returned `setof profiles` which leaked
--      the hash to the client even though the function ran
--      as SECURITY DEFINER (column-revoke only protects direct
--      table SELECTs, not function return columns).

-- 1. phone_is_set generated column.
-- Postgres re-computes generated columns on insert/update;
-- adding the column with ALTER TABLE backfills every existing
-- row via a table rewrite.
alter table public.profiles
    add column if not exists phone_is_set boolean
    generated always as (phone_e164_hash is not null) stored;

-- 2. Column-level REVOKE for the sensitive hash.
revoke select (phone_e164_hash) on public.profiles
    from authenticated, anon;

-- 3. Recreate match_contacts_by_phone with an explicit return
-- type that omits the hash. Drop+recreate because changing a
-- function's RETURNS clause isn't supported via OR REPLACE.
drop function if exists public.match_contacts_by_phone(text[]);

create or replace function public.match_contacts_by_phone(
    hashes text[]
)
returns table (
    id uuid,
    username text,
    display_name text,
    avatar_url text,
    bio text,
    is_pro boolean,
    created_at timestamptz,
    phone_is_set boolean
)
language plpgsql
security definer
set search_path = public
as $func$
begin
    if auth.uid() is null then
        raise exception 'must be authenticated';
    end if;

    return query
    select
      p.id,
      p.username,
      p.display_name,
      p.avatar_url,
      p.bio,
      p.is_pro,
      p.created_at,
      p.phone_is_set
    from public.profiles p
    where p.phone_e164_hash = any (hashes)
      and p.id <> auth.uid();
end;
$func$;

grant execute on function public.match_contacts_by_phone(text[])
    to authenticated;
