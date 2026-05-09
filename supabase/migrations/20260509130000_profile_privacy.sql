-- ============================================
-- Profile privacy
-- Adds opt-in `profiles.is_private` and rewrites the outfits SELECT
-- policy so that posts authored by a private profile are only visible
-- to:
--   • the author themselves
--   • viewers who follow the author
-- Public outfits from non-private profiles continue to be visible to
-- everyone (matching prior behaviour).
-- ============================================

-- 1. Schema: add the privacy flag, default false (existing rows
--    untouched; everyone stays public unless explicitly flipped).
alter table public.profiles
  add column if not exists is_private boolean not null default false;

-- 2. RLS: replace the existing outfits SELECT policy with one that
--    consults the author's privacy flag and the viewer's follow list.
drop policy if exists "Public outfits viewable by everyone" on public.outfits;

create policy "Outfits visible per profile privacy"
  on public.outfits for select using (
    -- Authors always see their own outfits, regardless of privacy.
    auth.uid() = user_id
    or (
      is_public
      and (
        -- Author profile is not private → visible to everyone.
        not exists (
          select 1 from public.profiles p
          where p.id = outfits.user_id and p.is_private = true
        )
        -- Author profile is private but viewer follows them.
        or exists (
          select 1 from public.follows f
          where f.follower_id = auth.uid()
            and f.following_id = outfits.user_id
        )
      )
    )
  );
