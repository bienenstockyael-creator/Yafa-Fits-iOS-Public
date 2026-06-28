-- ============================================================
-- SECURITY: cap match_contacts_by_phone input size
--
-- The RPC accepts an arbitrary array of SHA-256 phone hashes and returns
-- the matching profiles. With no cap, it can be abused to brute-force /
-- enumerate the phone->account space (a phone-number reverse directory).
-- This adds a hard per-call array cap (a real contact sync sends a
-- bounded list). NOTE: a per-call cap is not a full defense on its own —
-- an attacker can still make many calls. Add per-user/day RATE LIMITING
-- at the API gateway (or a call-count table) as a follow-up.
-- ============================================================

create or replace function public.match_contacts_by_phone(hashes text[])
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

    if hashes is null or array_length(hashes, 1) is null then
        return;
    end if;

    -- Hard cap: a genuine contact sync is bounded; reject mass dumps.
    if array_length(hashes, 1) > 1500 then
        raise exception 'too many hashes (max 1500 per call)';
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

grant execute on function public.match_contacts_by_phone(text[]) to authenticated;
