-- Track whether a product's thumbnail is still being generated.
--
-- The iOS Share Extension inserts a wishlist row instantly with the raw
-- retailer image (thumb_status='generating'), then the share-save Edge
-- Function polishes it with FAL in the background and flips it to 'ready'.
-- The closet shows the app's sparkle overlay while a row is 'generating'.
--
-- Additive + backfilled: every existing row defaults to 'ready', so nothing
-- already in a closet shows the overlay.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS thumb_status text NOT NULL DEFAULT 'ready';
