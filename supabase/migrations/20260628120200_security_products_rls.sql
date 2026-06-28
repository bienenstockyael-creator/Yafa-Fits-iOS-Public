-- ============================================================
-- SECURITY: track public.products RLS in source control
--
-- The products table (closet / wishlist) was created out-of-band in the
-- Supabase SQL editor, so its RLS lived only on the live DB and was
-- invisible to source control. A live anon probe confirmed the table is
-- already protected (anon reads return zero rows), so this is NOT an
-- active leak — it makes the protection explicit + reproducible so a
-- future table recreation can't silently lose it.
--
-- Idempotent and additive. The owner-scoped policies below are all
-- restrictive (auth.uid() = user_id), so even if a differently-named
-- policy already exists, these can only ever narrow access. After
-- applying, verify on the live DB that there is NO permissive
-- `using (true)` SELECT policy left over:
--   select polname, qual from pg_policies where tablename = 'products';
-- ============================================================

alter table public.products enable row level security;

-- Remove the earlier out-of-band ALL policy; the products_owner_* policies
-- below are the tracked source of truth (both were owner-scoped, so this is
-- not an access change — just de-duplication).
drop policy if exists "Users manage own products" on public.products;

drop policy if exists "products_owner_select" on public.products;
create policy "products_owner_select" on public.products
  for select using (auth.uid() = user_id);

drop policy if exists "products_owner_insert" on public.products;
create policy "products_owner_insert" on public.products
  for insert with check (auth.uid() = user_id);

drop policy if exists "products_owner_update" on public.products;
create policy "products_owner_update" on public.products
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "products_owner_delete" on public.products;
create policy "products_owner_delete" on public.products
  for delete using (auth.uid() = user_id);
