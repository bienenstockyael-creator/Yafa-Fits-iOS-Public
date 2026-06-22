-- TEMPORARY (beta): unlimited 3D generation credits for everyone.
--
-- Until the StoreKit IAP credit-purchase flow ships, no one should hit
-- a credit wall. The credit gate is reserve_3d_credit(): the app calls
-- it at generation time and blocks only when it returns 'none'. This
-- redefinition makes it ALWAYS grant — tagging the job 'pro', the
-- existing "unlimited, no balance consumed, refund-safe" source — so
-- generation is never blocked. It deliberately does NOT set
-- profiles.is_pro = true, because is_pro also drives the cosmetic Pro
-- feed-card styling (PublicFeedListView showsProChrome).
--
-- It also bumps the visible balance so the profile credit chip reads
-- generously instead of freezing at a low number that never moves
-- (reserve no longer decrements it).
--
-- ┌─ TO REVERT WHEN IAP SHIPS ────────────────────────────────────────┐
-- │ 1. Restore reserve_3d_credit() from                               │
-- │    20260517100000_3d_credit_system.sql (the balance-checking body).│
-- │ 2. Reset balances + default to the real values, e.g.:            │
-- │      update public.profiles set gen_credits_free_balance = 6;     │
-- │      alter table public.profiles                                  │
-- │        alter column gen_credits_free_balance set default 6;       │
-- └───────────────────────────────────────────────────────────────────┘

-- 1. Gate: always grant. Keeps the ownership/auth + idempotency checks;
--    drops the balance/is_pro branches in favor of an unconditional grant.
create or replace function public.reserve_3d_credit(p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_user_id uuid;
  v_existing text;
begin
  select user_id, credit_source
  into v_user_id, v_existing
  from public.generation_jobs
  where id = p_job_id;

  if v_user_id is null then
    raise exception 'generation_jobs row % not found', p_job_id;
  end if;
  if v_user_id <> auth.uid() then
    raise exception 'not allowed';
  end if;

  -- Idempotent: a re-reserve of an already-reserved job returns the
  -- existing source without re-tagging.
  if v_existing is not null then
    return v_existing;
  end if;

  -- Beta: unlimited for everyone. 'pro' = no balance consumed, and
  -- release_3d_credit() no-ops for 'pro', so the refund path is safe.
  update public.generation_jobs
  set credit_source = 'pro'
  where id = p_job_id;
  return 'pro';
end;
$func$;

-- create-or-replace preserves grants, but re-assert defensively.
grant execute on function public.reserve_3d_credit(uuid) to authenticated;

-- 2. Display: give every existing user a generous, non-resetting balance
--    so the profile credit chip doesn't freeze at a low count. Runs as
--    the migration owner, so the C1 client-write lockdown doesn't apply.
update public.profiles
set gen_credits_free_balance = 999,
    gen_credits_reset_at = null;

-- 3. New signups start generous too.
alter table public.profiles
  alter column gen_credits_free_balance set default 999;
