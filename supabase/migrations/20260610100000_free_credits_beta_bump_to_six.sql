-- Beta soft-launch: bump free monthly credit grant from 3 to 6.
--
-- Why: paid credits are intentionally hidden during the beta
-- TestFlight rollout ("Coming soon" paywall — see
-- CreditPaywallHost.paidCreditsEnabled = false). Doubling the
-- free monthly cap gives users meaningful headroom without
-- pushing them into an unavailable purchase flow. Still a cap so
-- generation costs stay bounded: at $0.72/gen and 6/user/month,
-- worst case per user is $4.32 in FAL costs.
--
-- Reverts back to 3 when paid tiers ship — flip the literal 6s
-- in this file back to 3 (or write a new migration). No data
-- migration needed; existing balances are untouched.
--
-- Touches three places where the cap was hardcoded in the credit
-- system (see 20260517100000_3d_credit_system.sql and
-- 20260607200000_free_credits_carryover.sql):
--
--   1. New profile default — column DEFAULT 3 → 6 so newly
--      signed-up TestFlight users start with the higher cap.
--      Existing users are NOT retroactively bumped (intentional
--      — they'll get +6 at next monthly refresh instead of an
--      uneven one-time +3).
--
--   2. Monthly refresh add amount — was +3, now +6. Combined
--      with the carryover behavior (no upper limit), light users
--      accumulate faster.
--
--   3. Release-clears-clock threshold — was `balance >= 3`, now
--      `>= 6`. Matches the new "full balance after grant" idea
--      so the rolling 30-day window cancels at the same logical
--      state.

-- 1. New profile default
alter table public.profiles
  alter column gen_credits_free_balance set default 6;

-- 2. Monthly refresh: add 6 (was 3 in the carryover migration)
create or replace function public.refresh_free_credits_if_due(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
begin
  update public.profiles
  set
    gen_credits_free_balance = gen_credits_free_balance + 6,
    gen_credits_reset_at = null
  where id = p_user_id
    and gen_credits_reset_at is not null
    and now() > gen_credits_reset_at;
end;
$func$;

-- 3. Release: clear rolling window when balance recovers to 6+
create or replace function public.release_3d_credit(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_user_id uuid;
  v_source text;
begin
  select user_id, credit_source
  into v_user_id, v_source
  from public.generation_jobs
  where id = p_job_id;

  if v_user_id is null then
    raise exception 'generation_jobs row % not found', p_job_id;
  end if;
  if v_user_id <> auth.uid() then
    raise exception 'not allowed';
  end if;
  if v_source is null then
    return;
  end if;

  if v_source = 'free' then
    update public.profiles
    set gen_credits_free_balance = gen_credits_free_balance + 1
    where id = v_user_id;
    update public.profiles
    set gen_credits_reset_at = null
    where id = v_user_id
      and gen_credits_free_balance >= 6;
  elsif v_source = 'paid' then
    update public.profiles
    set gen_credits_paid_balance = gen_credits_paid_balance + 1
    where id = v_user_id;
  end if;
  -- 'pro' source: no balance change.

  update public.generation_jobs
  set credit_source = null
  where id = p_job_id;
end;
$func$;
