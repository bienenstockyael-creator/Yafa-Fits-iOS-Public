-- Import Marvin's 4 outfits from yael-fits web repo into @marvin profile.
-- Frames remain hosted at yael-fits.vercel.app (no storage migration).

begin;

do $check$
begin
  if not exists (select 1 from public.profiles where username = 'marvin') then
    raise exception 'profile @marvin not found';
  end if;
end
$check$;

with target as (
  select id from public.profiles where username = 'marvin'
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
  ('marvin-outfit-74', 'Outfit 74', date '2026-05-06', 'outfit-74', 'Marvin_03_', 45,  7, 'Clear',  timestamptz '2026-05-06 19:10:00+00'),
  ('marvin-outfit-72', 'Outfit 72', date '2026-04-19', 'outfit-72', 'Marvin_01_', 48,  9, 'Cloudy', timestamptz '2026-04-19 10:50:00+00'),
  ('marvin-outfit-73', 'Outfit 73', date '2026-03-30', 'outfit-73', 'Marvin_02_', 52, 11, 'Cloudy', timestamptz '2026-03-30 15:35:00+00'),
  ('marvin-outfit-75', 'Outfit 75', date '2026-03-08', 'outfit-75', 'Marvin_04_', 50, 10, 'Cloudy', timestamptz '2026-03-08 21:00:00+00')
) as v(id, name, date, folder, prefix, tf, tc, cond, published_at);

select id, date, published_at, weather_condition, is_public
from public.outfits
where id like 'marvin-outfit-%'
order by published_at desc;

commit;
