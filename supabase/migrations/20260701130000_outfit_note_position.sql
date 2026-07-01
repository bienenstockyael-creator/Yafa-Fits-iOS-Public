-- Free positioning for diary notes (drag + pinch, Instagram-style).
-- note_x / note_y are normalized 0..1 within the fit frame (0.5,0.5 = center);
-- note_scale is the pinch zoom factor (1.0 = default).
alter table public.outfits
  add column if not exists note_x double precision,
  add column if not exists note_y double precision,
  add column if not exists note_scale double precision;
