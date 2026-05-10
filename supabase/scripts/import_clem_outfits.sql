-- Import Clem's 2 outfits from yael-fits web repo into @lem profile.
-- Frames remain hosted at yael-fits.vercel.app (no storage migration).

begin;

do $check$
begin
  if not exists (select 1 from public.profiles where username = 'lem') then
    raise exception 'profile @lem not found';
  end if;
end
$check$;

with target as (
  select id from public.profiles where username = 'lem'
)
insert into public.outfits (
  id, user_id, name, date, frame_count, folder, prefix, frame_ext,
  scale, is_rotation_reversed, tags, activity,
  weather_temp_f, weather_temp_c, weather_condition,
  is_public, published_at, remote_base_url
)
select
  v.id, target.id, v.name, v.date, 242, v.folder, v.prefix, 'webp',
  1.0, false, '{}'::text[], null,
  v.tf, v.tc, v.cond,
  true, v.published_at, 'https://yael-fits.vercel.app/outfits/'
from target,
(values
  ('lem-outfit-76', 'Outfit 76', date '2026-05-04', 'outfit-76', 'Clem_01_', 46,  8, 'Cloudy', timestamptz '2026-05-04 12:40:00+00'),
  ('lem-outfit-77', 'Outfit 77', date '2026-03-22', 'outfit-77', 'Clem_02_', 50, 10, 'Cloudy', timestamptz '2026-03-22 17:25:00+00')
) as v(id, name, date, folder, prefix, tf, tc, cond, published_at);

select id, date, published_at, weather_condition, is_public
from public.outfits
where id like 'lem-outfit-%'
order by published_at desc;

commit;
