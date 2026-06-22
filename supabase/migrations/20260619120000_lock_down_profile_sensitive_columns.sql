-- C1 fix: stop clients from writing their own credit balance / Pro status.
--
-- Credit balances (gen_credits_free_balance, gen_credits_paid_balance,
-- gen_credits_reset_at) and is_pro live as plain columns on
-- public.profiles. The existing RLS UPDATE policy ("Users can update
-- own profile" USING auth.uid() = id) is ROW-scoped but NOT
-- column-scoped, so any authenticated user could rewrite their own
-- credits / is_pro directly via the public anon key — bypassing the
-- entire IAP + credit-grant trust boundary.
--
-- Postgres column-level privileges fix this without touching RLS: we
-- revoke blanket UPDATE/INSERT from the client roles and re-grant only
-- the non-sensitive, user-editable columns. The SECURITY DEFINER credit
-- RPCs (reserve_3d_credit, refresh_free_credits_if_due,
-- grant_paid_credits) run as the function owner and are unaffected, so
-- legitimate server-side credit writes keep working. Account creation is
-- likewise unaffected: handle_new_user() is SECURITY DEFINER.
--
-- Allowlist == every column the iOS client legitimately writes:
--   avatar_url (AvatarService), phone_e164_hash (PhoneUpdate),
--   header_style/header_accent_color/avatar_cutout_url (HeaderUpdate),
--   is_onboarded (OnboardingUpdate),
--   username/display_name/bio (ProfileUpsertFull), is_private (pref).
-- Deliberately EXCLUDED: gen_credits_free_balance, gen_credits_paid_balance,
--   gen_credits_reset_at, is_pro (server-only), credit_source (on
--   generation_jobs, not here), phone_is_set (generated column).

-- UPDATE: revoke table-wide, re-grant only the safe columns.
revoke update on public.profiles from anon, authenticated;

grant update (
  username,
  display_name,
  avatar_url,
  avatar_cutout_url,
  bio,
  is_private,
  header_style,
  header_accent_color,
  is_onboarded,
  phone_e164_hash
) on public.profiles to authenticated;

-- INSERT: same allowlist (+ id). The signup row is created by the
-- SECURITY DEFINER handle_new_user() trigger (unaffected by these
-- grants); the only client-side INSERT is the profile upsert, which
-- writes id/username/display_name/avatar_url/bio. Restricting columns
-- here closes the (near-impossible) "no existing row" credit-injection
-- edge case as defense in depth.
revoke insert on public.profiles from anon, authenticated;

grant insert (
  id,
  username,
  display_name,
  avatar_url,
  avatar_cutout_url,
  bio,
  is_private,
  header_style,
  header_accent_color,
  is_onboarded,
  phone_e164_hash
) on public.profiles to authenticated;
