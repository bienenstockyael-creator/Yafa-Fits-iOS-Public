-- Aggregate archive stats for visitor profiles: how big is this
-- member's WHOLE archive (public + private) and when did they last
-- log a fit. Solves "active private loggers look dead": visitors see
-- "N fits in the private archive" + "logged today" without RLS ever
-- exposing the private rows themselves — this function returns two
-- scalars, nothing more.
--
-- Private ACCOUNTS (profiles.is_private) return zero/null so a
-- locked account leaks nothing, matching the rest of the app.

create or replace function public.profile_archive_stats(p_user_id uuid)
returns table(total_fits int, last_fit_at timestamptz)
language sql
security definer
set search_path = public
as $func$
  select
    case when coalesce(pr.is_private, false) then 0
         else (select count(*)::int from public.outfits o where o.user_id = p_user_id) end,
    case when coalesce(pr.is_private, false) then null
         else (select max(o.created_at) from public.outfits o where o.user_id = p_user_id) end
  from public.profiles pr
  where pr.id = p_user_id;
$func$;

revoke execute on function public.profile_archive_stats(uuid) from public, anon;
grant execute on function public.profile_archive_stats(uuid) to authenticated;
