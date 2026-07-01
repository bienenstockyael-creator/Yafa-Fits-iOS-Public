-- ============================================================
-- Diary notes on outfits — a personal annotation the owner writes on
-- each fit in the carousel detail view. Private by default; the owner
-- opts in to sharing it (shown to viewers + on the share card) via the
-- Publish sheet toggle.
-- ============================================================

alter table public.outfits
  add column if not exists diary_note text,
  add column if not exists note_style text,
  add column if not exists note_shared boolean not null default false;
