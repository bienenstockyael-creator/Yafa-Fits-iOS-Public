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

-- 2. Reset the inflated beta default (999) to your real monthly free
--    allowance. *** ADJUST 3 to whatever your launch free grant is. ***
alter table public.profiles
  alter column gen_credits_free_balance set default 3;

-- 3. (OPTIONAL — product decision) Bring existing users' inflated 999
--    beta balances down to a sane cap. Leave commented to grandfather
--    beta testers; uncomment to reset everyone to the launch cap.
-- update public.profiles
--   set gen_credits_free_balance = least(gen_credits_free_balance, 6)
--   where gen_credits_free_balance > 6;

-- 4. RECOMMENDED: also cap free-credit carryover so inactive users can't
--    bank unlimited free generations (refresh_free_credits_if_due adds 6
--    per window with no upper bound). Edit that function to:
--    gen_credits_free_balance = least(gen_credits_free_balance + 6, 12)
