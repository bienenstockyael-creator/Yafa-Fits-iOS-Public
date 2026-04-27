-- Adds the `published_at` column to outfits + a trigger that auto-fills it
-- whenever `is_public` flips to true without an explicit value. The trigger
-- protects the feed-visibility query (which requires published_at IS NOT NULL)
-- from older client builds that flip is_public without setting published_at.

alter table public.outfits
  add column if not exists published_at timestamptz;

create or replace function public.set_published_at_on_publish()
returns trigger language plpgsql as $$
begin
  if new.is_public = true and new.published_at is null then
    new.published_at = now();
  end if;
  return new;
end$$;

drop trigger if exists outfits_auto_published_at on public.outfits;
create trigger outfits_auto_published_at
  before insert or update on public.outfits
  for each row execute function public.set_published_at_on_publish();
