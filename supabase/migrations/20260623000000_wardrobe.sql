-- Wardrobe (product closet) — Phase 0 foundation.
--
-- Extends the existing `public.products` table into a first-class
-- wardrobe: every tagged product is a user-owned item that outfits
-- reference, filterable by category/status, with fuzzy dedup at tag
-- time. Fully ADDITIVE and backward-compatible — the currently
-- shipped app ignores columns it doesn't know about, so applying
-- this does not affect live testers.
--
-- NOTE: the ALTER/CREATE INDEX block below was already applied to
-- production via the SQL editor on 2026-06-23; it is captured here
-- (idempotent) so the schema lives in version control. The
-- `find_similar_products` function at the bottom is NOT yet applied
-- and is only needed once the tagging dedup hook ships.

create extension if not exists pg_trgm;

alter table public.products
  add column if not exists brand      text,
  add column if not exists color      text,
  add column if not exists category   text not null default 'unknown',
  add column if not exists price      text,
  add column if not exists source_url text,
  add column if not exists status     text not null default 'owned';

-- Normalized name for fuzzy "already in your closet?" matching.
alter table public.products
  add column if not exists norm_name text
  generated always as (lower(btrim(name))) stored;

create index if not exists products_norm_name_trgm_idx
  on public.products using gin (norm_name gin_trgm_ops);

create index if not exists products_user_id_idx
  on public.products (user_id);

alter table public.products
  drop constraint if exists products_status_check;
alter table public.products
  add constraint products_status_check check (status in ('owned', 'wishlist'));

-- RPC: fuzzy similar-item lookup for the tagging dedup strip.
-- RLS-scoped to the caller via the explicit user_id filter (and
-- security invoker, so the table's RLS also applies). Uses the
-- pg_trgm `%` operator (similarity above the threshold) and orders
-- by descending similarity.
create or replace function public.find_similar_products(
  p_query text,
  p_limit int default 5
)
returns setof public.products
language sql
stable
security invoker
as $func$
  select *
  from public.products
  where user_id = auth.uid()
    and norm_name % lower(btrim(p_query))
  order by similarity(norm_name, lower(btrim(p_query))) desc
  limit greatest(p_limit, 1);
$func$;

grant execute on function public.find_similar_products(text, int) to authenticated;
