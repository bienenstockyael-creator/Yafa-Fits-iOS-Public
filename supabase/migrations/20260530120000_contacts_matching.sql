-- Contact matching for the "Find your people" flow.
--
-- Stores a SHA-256 hash of the user's normalized E.164 phone
-- number on their profile. Clients hash both their own phone
-- (when they opt in) and the phones from their device's
-- Contacts list, then ask this RPC which of those hashes
-- correspond to existing Yafa profiles. Raw phone numbers
-- never leave the device.
--
-- Privacy note: SHA-256 of a phone number is brute-forceable
-- if the hash leaks (the space is only ~10^11 valid numbers).
-- For stronger guarantees you'd want OPRF or signed phone
-- tokens — out of scope here. The hash column is readable by
-- any authenticated user via `select *` on profiles; we
-- accept that tradeoff for V1.

alter table public.profiles
    add column if not exists phone_e164_hash text;

-- Hash lookup is the hot path during contact matching.
-- Partial index skips the (vast majority of) rows where the
-- user hasn't added a phone yet.
create index if not exists profiles_phone_e164_hash_idx
    on public.profiles(phone_e164_hash)
    where phone_e164_hash is not null;

-- The matching RPC. Takes a list of client-computed phone
-- hashes and returns the matching profiles. Runs as DEFINER
-- so it doesn't depend on whatever RLS policies the profiles
-- table currently has — guarantees the matching behavior is
-- stable even if those policies change.
create or replace function public.match_contacts_by_phone(
    hashes text[]
)
returns setof public.profiles
language plpgsql
security definer
set search_path = public
as $func$
begin
    -- Authenticated callers only — anonymous traffic can't
    -- enumerate user phone hashes.
    if auth.uid() is null then
        raise exception 'must be authenticated';
    end if;

    return query
    select p.*
    from public.profiles p
    where p.phone_e164_hash = any (hashes)
      and p.id <> auth.uid();
end;
$func$;

grant execute on function public.match_contacts_by_phone(text[])
    to authenticated;
