-- ============================================================
-- One-time redeemable access codes (control who can use the public app)
--
-- Anyone can sign in, but must redeem a single-use code to get `has_access`.
-- Existing users are grandfathered (kept). New signups start gated.
-- Codes + the flag are server-only — clients cannot read codes or self-grant
-- access (has_access is excluded from the client UPDATE allowlist by the C1
-- lockdown; only the SECURITY DEFINER redeem RPC, running as owner, sets it).
-- ============================================================

-- 1. Access flag on profiles. Default false (new signups gated).
alter table public.profiles
  add column if not exists has_access boolean not null default false;

-- 2. Grandfather everyone who already exists (run again right before the gated
--    build goes live to catch anyone who signed up in the meantime).
update public.profiles set has_access = true;

-- 3. The codes table. RLS enabled with NO client policies => clients can't read
--    or write it; only the redeem RPC (security definer) touches it.
create table if not exists public.access_codes (
  code        text primary key,
  note        text,
  created_at  timestamptz not null default now(),
  redeemed_by uuid references auth.users(id) on delete set null,
  redeemed_at timestamptz
);
alter table public.access_codes enable row level security;

-- 4. Redeem RPC — race-safe (atomic claim), idempotent, returns a status:
--    'ok' | 'already_used' | 'invalid'.
create or replace function public.redeem_access_code(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_uid uuid := auth.uid();
  v_norm text := upper(trim(coalesce(p_code, '')));
  v_claimed int;
begin
  if v_uid is null then
    raise exception 'must be authenticated';
  end if;

  -- Already has access -> no-op success.
  if exists (select 1 from public.profiles where id = v_uid and has_access) then
    return 'ok';
  end if;

  if v_norm = '' then
    return 'invalid';
  end if;

  -- Atomically claim an unredeemed code (only one redeemer can win the race).
  update public.access_codes
  set redeemed_by = v_uid, redeemed_at = now()
  where code = v_norm and redeemed_by is null;
  get diagnostics v_claimed = row_count;

  if v_claimed = 0 then
    -- This user already redeemed this exact code earlier -> treat as success.
    if exists (select 1 from public.access_codes where code = v_norm and redeemed_by = v_uid) then
      update public.profiles set has_access = true where id = v_uid;
      return 'ok';
    end if;
    -- Code exists but is taken by someone else.
    if exists (select 1 from public.access_codes where code = v_norm) then
      return 'already_used';
    end if;
    return 'invalid';
  end if;

  -- Claim succeeded -> grant access.
  update public.profiles set has_access = true where id = v_uid;
  return 'ok';
end;
$func$;

revoke all on function public.redeem_access_code(text) from public, anon;
grant execute on function public.redeem_access_code(text) to authenticated;
