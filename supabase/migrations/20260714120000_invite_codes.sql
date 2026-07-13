-- ============================================================
-- User-minted invite codes (chrome card flip-to-reveal)
--
-- Extends the existing access_codes gate: codes gain an OWNER
-- (inviter_id) and owners gain a QUOTA (profiles.invite_quota,
-- default 0 — Yael grants invite power per user). Redemption is
-- UNCHANGED: the existing redeem_access_code RPC claims invite
-- codes exactly like manually-minted ones, so the app's gate
-- screen needs no changes. inviter_id + redeemed_by together
-- form the referral graph.
--
-- Everything here is additive and safe to apply while 1.1 is
-- live: nothing gates harder than today, and no client behavior
-- changes until the card-back UI ships and quotas are granted.
-- ============================================================

-- 1. Who may invite, and how much. Default 0: invite power is
--    granted explicitly (e.g. tastemakers 10, friends 3).
alter table public.profiles
  add column if not exists invite_quota int not null default 0;

-- 2. Codes gain an owner. Manual codes keep inviter_id null.
alter table public.access_codes
  add column if not exists inviter_id uuid references public.profiles(id) on delete set null;

create index if not exists access_codes_inviter_idx
  on public.access_codes (inviter_id) where inviter_id is not null;

-- 3. The card-back RPC. Returns the caller's current shareable
--    code, minting one if needed and quota allows. One active
--    (unredeemed) code at a time: a new code is only minted after
--    the previous one is claimed, so quota = people brought in,
--    not codes hoarded.
--    Returns: code text, state text ('active'|'exhausted'|'no_quota'),
--             used int, quota int.
create or replace function public.current_invite_code()
returns table (code text, state text, used int, quota int)
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_uid uuid := auth.uid();
  v_quota int;
  v_used int;
  v_active text;
  v_new text;
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I/L
  v_tries int := 0;
begin
  if v_uid is null then
    raise exception 'must be authenticated';
  end if;

  select p.invite_quota into v_quota from public.profiles p where p.id = v_uid;
  if v_quota is null then
    raise exception 'no profile';
  end if;

  -- Codes already claimed through this inviter.
  select count(*) into v_used
  from public.access_codes c
  where c.inviter_id = v_uid and c.redeemed_by is not null;

  if v_quota <= 0 then
    return query select null::text, 'no_quota'::text, v_used, v_quota;
    return;
  end if;

  -- An unredeemed code is the current one — keep showing it.
  select c.code into v_active
  from public.access_codes c
  where c.inviter_id = v_uid and c.redeemed_by is null
  order by c.created_at desc
  limit 1;
  if v_active is not null then
    return query select v_active, 'active'::text, v_used, v_quota;
    return;
  end if;

  if v_used >= v_quota then
    return query select null::text, 'exhausted'::text, v_used, v_quota;
    return;
  end if;

  -- Mint: YAFA-XXXX from an unambiguous alphabet, retry on the
  -- (unlikely) collision.
  loop
    v_tries := v_tries + 1;
    v_new := 'YAFA-' ||
      substr(v_alphabet, 1 + floor(random() * 31)::int, 1) ||
      substr(v_alphabet, 1 + floor(random() * 31)::int, 1) ||
      substr(v_alphabet, 1 + floor(random() * 31)::int, 1) ||
      substr(v_alphabet, 1 + floor(random() * 31)::int, 1);
    begin
      insert into public.access_codes (code, note, inviter_id)
      values (v_new, 'invite', v_uid);
      exit;
    exception when unique_violation then
      if v_tries > 20 then
        raise exception 'could not mint a unique code';
      end if;
    end;
  end loop;

  return query select v_new, 'active'::text, v_used, v_quota;
end;
$func$;

revoke all on function public.current_invite_code() from public, anon;
grant execute on function public.current_invite_code() to authenticated;

-- 4. Claimed-invite history for the card back ("Claimed by @…").
create or replace function public.my_claimed_invites()
returns table (code text, redeemed_at timestamptz, claimed_by_username text, claimed_by_display_name text, claimed_by_avatar_url text)
language sql
security definer
set search_path = public
stable
as $func$
  select c.code, c.redeemed_at, p.username, p.display_name, p.avatar_url
  from public.access_codes c
  left join public.profiles p on p.id = c.redeemed_by
  where c.inviter_id = auth.uid() and c.redeemed_by is not null
  order by c.redeemed_at desc;
$func$;

revoke all on function public.my_claimed_invites() from public, anon;
grant execute on function public.my_claimed_invites() to authenticated;

-- ============================================================
-- Granting invite power (run as needed):
--   update public.profiles set invite_quota = 3
--   where username = 'someone';
-- Yael herself:
--   update public.profiles set invite_quota = 100
--   where id = '31C9F3FD-E672-43F2-954A-0B141640E76F';
-- ============================================================
