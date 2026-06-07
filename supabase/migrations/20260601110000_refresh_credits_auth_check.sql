-- Adds an `auth.uid()` check to `refresh_free_credits_if_due`.
--
-- The function takes `p_user_id uuid` and is granted to
-- `authenticated`. The body's UPDATE is harmless (only restores
-- credits when the 30-day window is up) so the worst a malicious
-- caller could do is force-reset another user's clock if they
-- happen to know that user's UUID — benign, but inconsistent
-- with the pattern in `reserve_3d_credit` / `commit_3d_credit` /
-- `release_3d_credit` which all reject mismatched callers.
--
-- This patch closes that hygiene gap.

create or replace function public.refresh_free_credits_if_due(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
begin
  -- Only the row owner can refresh their own credits.
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'not allowed';
  end if;

  update public.profiles
  set
    gen_credits_free_balance = 3,
    gen_credits_reset_at = null
  where id = p_user_id
    and gen_credits_reset_at is not null
    and now() > gen_credits_reset_at;
end;
$func$;
