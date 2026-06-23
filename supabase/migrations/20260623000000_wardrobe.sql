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
--
-- Searches the UNION of the caller's `products` rows AND the inline
-- products tagged on their own outfits (`outfit_products` with no
-- `product_id`) — most legacy tags live inline, so a products-only
-- search surfaced almost nothing. Deduped by normalized name
-- (preferring the real products row). Matches by substring (either
-- direction) OR trigram similarity, so short queries like "blue"
-- still find "Blue Jeans". RLS-scoped via auth.uid() + security
-- invoker.
drop function if exists public.find_similar_products(text, int);

create function public.find_similar_products(
  p_query text,
  p_limit int default 6
)
returns table (
  name text,
  image_url text,
  source_url text,
  price text,
  product_id uuid
)
language sql
stable
security invoker
as $func$
  with cand as (
    select p.name, p.image_url, p.source_url, p.price, p.id as product_id,
           lower(btrim(p.name)) as norm
    from public.products p
    where p.user_id = auth.uid()
    union all
    select op.name, op.image as image_url, op.shop_link as source_url,
           op.price, null::uuid as product_id,
           lower(btrim(op.name)) as norm
    from public.outfit_products op
    join public.outfits o on o.id = op.outfit_id
    where o.user_id = auth.uid()
      and op.product_id is null
      and coalesce(op.name, '') <> ''
  ),
  dedup as (
    select distinct on (norm)
      name, image_url, source_url, price, product_id, norm
    from cand
    where norm <> ''
    order by norm, product_id nulls last
  ),
  q as (select lower(btrim(p_query)) as t)
  select d.name, d.image_url, d.source_url, d.price, d.product_id
  from dedup d cross join q
  where d.norm ilike '%' || q.t || '%'
     or q.t ilike '%' || d.norm || '%'
     or d.norm % q.t
  order by
    (d.norm = q.t) desc,
    (d.norm ilike q.t || '%') desc,
    similarity(d.norm, q.t) desc
  limit greatest(p_limit, 1);
$func$;

grant execute on function public.find_similar_products(text, int) to authenticated;
