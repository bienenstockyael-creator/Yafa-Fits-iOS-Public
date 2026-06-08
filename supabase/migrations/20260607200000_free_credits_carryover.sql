-- Free monthly credits — carry-over on refresh.
--
-- Original behavior (see 20260517100000_3d_credit_system.sql):
--   `refresh_free_credits_if_due` SET the balance to 3, wiping
--   any leftover credits from the prior window. A user who only
--   used 1 of their 3 free credits in month N would lose the
--   other 2 at the month boundary.
--
-- New behavior: ADD 3 to whatever's already in the free bucket.
-- Same monthly cadence, but unused credits roll over. Rewards
-- light users without changing the spending lifecycle.
--
-- Side-effect math to be aware of: with no upper cap, a user
-- who never generates ends up with 3·N credits after N months.
-- Intentional for v1 — if it grows uncomfortably large we can
-- add a CAP (e.g. min(balance + 3, 12)) in a follow-up. The
-- per-month grant is still 3, so the rate of accumulation is
-- bounded by absenteeism.

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
