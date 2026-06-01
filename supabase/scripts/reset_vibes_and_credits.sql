-- One-off reset for the vibes feature.
--
-- Run in Supabase SQL editor BEFORE the vibes feature ships
-- publicly, to wipe any data accumulated during dev/testing.
--
-- Effects:
--   1. Deletes every row in `public.vibes` (one row per
--      give-vibe action). The AFTER INSERT trigger that awards
--      credits only fires on INSERT, so DELETE doesn't re-award.
--   2. Resets every profile's `gen_credits_free_balance` back to
--      its default (3 free credits) and clears
--      `gen_credits_reset_at`, so the 30-day window starts fresh
--      next time someone consumes a free credit.
--
-- Idempotent: a second run is a no-op (vibes already empty,
-- credits already at default).

-- 1. Wipe the vibes table.
truncate table public.vibes restart identity;

-- 2. Reset credit balances and the consumption-window timer.
update public.profiles
set gen_credits_free_balance = 3,
    gen_credits_reset_at = null;
