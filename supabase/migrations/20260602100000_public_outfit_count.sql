-- RPC for "this user's public outfit count," visible to all
-- authenticated callers regardless of follow status or the target
-- user's privacy. Used to render the count on profile views.
--
-- Why this exists separate from a regular `select count(*) from
-- outfits where ...`: the `outfits` SELECT RLS policy hides
-- private users' outfits from non-followers. That correctly gates
-- the GRID (you can't see the rows) but also collapses the COUNT
-- to zero, so the profile shows "0 outfits" for a private user
-- you don't follow — even though they may have a healthy public
-- archive that would unlock if you followed. We want the count
-- to be a public signal (encourages follow requests) while the
-- content stays gated. This SECURITY DEFINER RPC threads that
-- needle: counts unconditionally, returns just the integer.
--
-- Owner's own profile uses the local `store.sortedOutfits.count`
-- (their full archive) and doesn't need this RPC.
create or replace function public.public_outfit_count(p_user_id uuid)
returns int
language sql
security definer
set search_path = public
stable
as $func$
    select count(*)::int
    from public.outfits
    where user_id = p_user_id
      and is_public = true;
$func$;

grant execute on function public.public_outfit_count(uuid) to authenticated;
