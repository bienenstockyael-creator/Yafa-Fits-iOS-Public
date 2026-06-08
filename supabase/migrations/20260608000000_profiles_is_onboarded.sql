-- Onboarding flag for the first-launch setup flow.
--
-- New users (sign-ups after this migration) get `is_onboarded =
-- false`. The iOS app checks the flag in `RootView` and presents
-- `OnboardingFlow` as a full-screen cover when false — walks the
-- user through display name → username → photo+style → phone,
-- then writes `is_onboarded = true` on Finish.
--
-- Existing users get backfilled to `true` so they aren't
-- re-prompted on their next session. They've already set up
-- whatever profile fields they're going to via the normal
-- settings flow.
--
-- The column is non-null so reads never have to handle a tri-
-- state (true / false / null). Default `false` so the row
-- created by Supabase's `handle_new_user` trigger (or any other
-- automatic profile-creation path) starts in the "needs to
-- onboard" state automatically.

alter table public.profiles
  add column if not exists is_onboarded boolean not null default false;

-- Backfill: every existing profile is considered already
-- onboarded. New rows from this point on default to false.
update public.profiles
set is_onboarded = true
where is_onboarded = false;
