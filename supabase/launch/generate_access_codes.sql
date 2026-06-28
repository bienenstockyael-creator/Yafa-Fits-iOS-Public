-- Mint access codes to hand out. Run in the Supabase SQL editor whenever you
-- need more. Codes are 8 uppercase hex chars (e.g. "9F3A1C7D"). Single-use.

-- Generate N codes (change 20):
insert into public.access_codes (code)
select upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
from generate_series(1, 20)
on conflict (code) do nothing;

-- List the codes that are still unredeemed, to copy + hand out:
select code, created_at
from public.access_codes
where redeemed_by is null
order by created_at desc;

-- (Optional) make a specific code for App Review notes:
-- insert into public.access_codes (code, note) values ('APPLEREVIEW1', 'app review');
