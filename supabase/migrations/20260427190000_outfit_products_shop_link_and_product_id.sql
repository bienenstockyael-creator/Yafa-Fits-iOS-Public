-- Recover missing columns on outfit_products that the iOS app expects.
--
-- These columns were used in production at some point (the app has always
-- read/written them) but were never tracked in schema.sql, and have gone
-- missing from the live database — causing PostgREST to error with
-- "column outfit_products.shop_link does not exist" and the join
-- "Could not find a relationship between 'outfits' and 'outfit_products'".
--
-- All operations are idempotent. Safe to re-run.

alter table public.outfit_products
  add column if not exists shop_link text;

alter table public.outfit_products
  add column if not exists product_id uuid;

-- FK to the products library, if that table exists. Wrapped in DO block
-- so this migration succeeds even if the products table isn't deployed yet.
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'products')
     and not exists (select 1 from information_schema.table_constraints
                     where table_schema = 'public'
                       and table_name = 'outfit_products'
                       and constraint_name = 'outfit_products_product_id_fkey') then
    alter table public.outfit_products
      add constraint outfit_products_product_id_fkey
      foreign key (product_id) references public.products(id) on delete set null;
  end if;
end$$;

-- Force PostgREST to reload its schema cache so the FK to outfits and the
-- new columns become visible to the REST API immediately.
notify pgrst, 'reload schema';
