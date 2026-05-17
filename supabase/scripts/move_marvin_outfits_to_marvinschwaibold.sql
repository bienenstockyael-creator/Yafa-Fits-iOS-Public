-- Re-attach all outfits owned by @marvin to @marvinschwaibold.
-- Keeps outfit IDs (marvin-outfit-*) and all FK refs (likes, comments,
-- outfit_products) intact — only user_id changes.

begin;

do $check$
begin
  if not exists (select 1 from public.profiles where username = 'marvin') then
    raise exception 'profile @marvin not found';
  end if;
  if not exists (select 1 from public.profiles where username = 'marvinschwaibold') then
    raise exception 'profile @marvinschwaibold not found';
  end if;
end
$check$;

update public.outfits
set user_id = (select id from public.profiles where username = 'marvinschwaibold')
where user_id = (select id from public.profiles where username = 'marvin');

-- Sanity: should show 0 outfits left on @marvin, all of them on @marvinschwaibold.
select p.username, count(o.id) as outfit_count
from public.profiles p
left join public.outfits o on o.user_id = p.id
where p.username in ('marvin', 'marvinschwaibold')
group by p.username
order by p.username;

commit;
