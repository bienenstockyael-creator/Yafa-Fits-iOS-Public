-- ============================================================
-- ⚠️  LAUNCH GATE — APPLY ONLY WHEN YOU ENABLE PAID CREDITS  ⚠️
--
-- This file is deliberately OUTSIDE supabase/migrations/ so that
-- `supabase db push` does NOT auto-apply it during beta. Applying it
-- early would make real users hit credit walls mid-beta.
--
-- Apply it (Supabase SQL editor, or move into migrations/) in the SAME
-- release where you flip `CreditPaywallHost.paidCreditsEnabled = true`.
-- It reverts the "beta unlimited credits" override
-- (20260619130000_beta_unlimited_credits.sql) back to real balance
-- enforcement. If you flip the app flag WITHOUT applying this, you will
-- charge for credits while still giving every generation away free.
-- ============================================================

-- 1. Restore the balance-checking reserve_3d_credit (verbatim from
--    20260517100000_3d_credit_system.sql). The beta override made this
--    unconditionally return 'pro' (no balance consumed) for everyone.
create or replace function public.reserve_3d_credit(p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_user_id uuid;
  v_existing text;
  v_is_pro boolean;
  v_free int;
  v_paid int;
  v_source text;
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

  if v_existing is not null then
    return v_existing;
  end if;

  perform public.refresh_free_credits_if_due(v_user_id);

  select coalesce(is_pro, false)
  into v_is_pro
  from public.profiles
  where id = v_user_id;

  if v_is_pro then
    update public.generation_jobs set credit_source = 'pro' where id = p_job_id;
    return 'pro';
  end if;

  select gen_credits_free_balance, gen_credits_paid_balance
  into v_free, v_paid
  from public.profiles
  where id = v_user_id
  for update;

  if v_free > 0 then
    update public.profiles
    set gen_credits_free_balance = gen_credits_free_balance - 1,
        gen_credits_reset_at = coalesce(gen_credits_reset_at, now() + interval '30 days')
    where id = v_user_id;
    v_source := 'free';
  elsif v_paid > 0 then
    update public.profiles
    set gen_credits_paid_balance = gen_credits_paid_balance - 1
    where id = v_user_id;
    v_source := 'paid';
  else
    return 'none';
  end if;

  update public.generation_jobs set credit_source = v_source where id = p_job_id;
  return v_source;
end;
$func$;

grant execute on function public.reserve_3d_credit(uuid) to authenticated;

-- 2. Revert the free monthly grant from the beta's 6 back to 3
--    (undoes 20260610100000_free_credits_beta_bump_to_six.sql). Three
--    places, all must match: the new-signup default, the monthly refresh
--    add amount, and the "rolling window clears" threshold.

-- 2a. New signups start with a 6-credit WELCOME grant (first-run delight) —
--     even though the ongoing monthly refresh is only 3 (set in 2b). The
--     column DEFAULT is the brand-new-user starting balance; existing users
--     are brought down to 3 in step 3. So: new users get 6 to start, then
--     +3/month thereafter; existing users start the paid era at 3.
alter table public.profiles
  alter column gen_credits_free_balance set default 6;

-- 2b. Monthly refresh adds 3 (was +6 in beta). Carries over (never expires).
create or replace function public.refresh_free_credits_if_due(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
begin
  update public.profiles
  set
    gen_credits_free_balance = gen_credits_free_balance + 3,
    gen_credits_reset_at = null
  where id = p_user_id
    and gen_credits_reset_at is not null
    and now() > gen_credits_reset_at;
end;
$func$;

-- 2c. Release-clears-clock threshold back to 3 (was 6 in beta), so the
--     30-day rolling window cancels at the right "full balance" state.
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
      and gen_credits_free_balance >= 3;
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

-- 3. Reset the inflated beta balances (999) down to the launch grant (3).
--    Paid balances live in a separate column (gen_credits_paid_balance) and
--    are untouched, so anyone who bought credits keeps every one of them.
update public.profiles
  set gen_credits_free_balance = 3
  where gen_credits_free_balance > 3;
