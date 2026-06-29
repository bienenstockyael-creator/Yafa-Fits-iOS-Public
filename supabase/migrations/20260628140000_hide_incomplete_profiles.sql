-- ============================================================
-- Hide incomplete / un-onboarded profiles from public listings
--
-- handle_new_user() creates a profiles row the moment a user AUTHENTICATES —
-- before they pick a username, and (with the access-code gate) before they
-- redeem a code. Those rows have no username/display name and leak into the
-- app as "User" in search + the suggested-people feed. Every curious person
-- who taps through sign-in without a code would become a ghost "User".
--
-- Fix: restrict the profiles SELECT policy so a profile is visible to OTHERS
-- only once it's onboarded; you can always see your OWN row (needed for the
-- gate, onboarding, and profile resolution while is_onboarded is still false).
--
-- Safe by construction: a gated/incomplete user has no outfits, vibes, follows
-- or comments, so nothing joins to their profile — hiding the row breaks no
-- existing feed/profile/comment query. Service-role edge functions bypass RLS
-- and are unaffected; anon (web/OG) still reads onboarded profiles, just not
-- ghosts.
-- ============================================================

drop policy if exists "Public profiles are viewable by everyone" on public.profiles;

create policy "Public profiles are viewable by everyone"
  on public.profiles for select using (
    is_onboarded = true
    or id = auth.uid()
  );
