-- ============================================================
-- SECURITY: outfit_products + comments must respect profile privacy
--
-- The outfits SELECT policy was rewritten to be privacy-aware in
-- 20260509130000_profile_privacy.sql (a private author's posts are only
-- visible to themselves + followers). But the CHILD-table policies for
-- outfit_products and comments still gated purely on `outfits.is_public`,
-- so a private author's tagged products (names/brands/prices/links) and
-- all comment bodies/authors leaked to non-followers who knew/guessed the
-- outfit id. This re-applies the exact outfits visibility logic to both.
-- ============================================================

drop policy if exists "Products viewable if outfit is viewable" on public.outfit_products;
create policy "Products viewable if outfit is viewable"
  on public.outfit_products for select using (
    exists (
      select 1 from public.outfits o
      where o.id = outfit_products.outfit_id
        and (
          auth.uid() = o.user_id
          or (
            o.is_public
            and (
              not exists (
                select 1 from public.profiles p
                where p.id = o.user_id and p.is_private = true
              )
              or exists (
                select 1 from public.follows f
                where f.follower_id = auth.uid() and f.following_id = o.user_id
              )
            )
          )
        )
    )
  );

drop policy if exists "Comments viewable on public outfits" on public.comments;
create policy "Comments viewable on public outfits"
  on public.comments for select using (
    exists (
      select 1 from public.outfits o
      where o.id = comments.outfit_id
        and (
          auth.uid() = o.user_id
          or (
            o.is_public
            and (
              not exists (
                select 1 from public.profiles p
                where p.id = o.user_id and p.is_private = true
              )
              or exists (
                select 1 from public.follows f
                where f.follower_id = auth.uid() and f.following_id = o.user_id
              )
            )
          )
        )
    )
  );
