-- Import Ella's 6 outfits from yael-fits web repo into @ella.jayes profile.
-- Frames remain hosted at yael-fits.vercel.app (no storage migration).
-- Run in Supabase SQL editor. Wrapped in a transaction; if anything fails,
-- nothing commits.

begin;

-- Guard: verify @ella.jayes exists before inserting anything.
do $check$
begin
  if not exists (select 1 from public.profiles where username = 'ella.jayes') then
    raise exception 'profile @ella.jayes not found';
  end if;
end
$check$;

with target as (
  select id from public.profiles where username = 'ella.jayes'
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
  ('ellajayes-outfit-68', 'Outfit 68', date '2026-05-08', 'outfit-68', 'Ella_15_', 82, 28, 'Sunny',  timestamptz '2026-05-08 14:30:00+00'),
  ('ellajayes-outfit-69', 'Outfit 69', date '2026-04-26', 'outfit-69', 'Ella_18_', 65, 18, 'Sunny',  timestamptz '2026-04-26 09:15:00+00'),
  ('ellajayes-outfit-66', 'Outfit 66', date '2026-04-12', 'outfit-66', 'Ella_05_', 52, 11, 'Cloudy', timestamptz '2026-04-12 11:20:00+00'),
  ('ellajayes-outfit-70', 'Outfit 70', date '2026-03-29', 'outfit-70', 'Ella_21_', 55, 13, 'Cloudy', timestamptz '2026-03-29 18:45:00+00'),
  ('ellajayes-outfit-67', 'Outfit 67', date '2026-03-15', 'outfit-67', 'Ella_06_', 38,  3, 'Cloudy', timestamptz '2026-03-15 16:00:00+00'),
  ('ellajayes-outfit-71', 'Outfit 71', date '2026-03-01', 'outfit-71', 'Ella_24_', 75, 24, 'Sunny',  timestamptz '2026-03-01 20:10:00+00')
) as v(id, name, date, folder, prefix, tf, tc, cond, published_at);

-- Sanity: should print 6 rows, all is_public=true, distinct dates.
select id, date, published_at, weather_condition, is_public
from public.outfits
where id like 'ellajayes-outfit-%'
order by published_at desc;

commit;
