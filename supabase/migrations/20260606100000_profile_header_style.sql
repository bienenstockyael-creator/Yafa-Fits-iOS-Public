-- Profile header customization: lets a user pick one of three
-- preset layouts for how their avatar + username display on
-- their own profile page (visible to everyone who views them).
--
-- Three styles:
--   * minimal: the current circular-avatar + name + bio layout
--   * curved:  username arcs in a pill around the avatar (same
--              component the empty-feed avatar bubbles use)
--   * bust:    avatar is background-removed (cutout), username
--              sits below in a highlighter-rectangle block
--
-- For `curved` and `bust`, the user also picks one of 4 vivid
-- accent colors (used for the curved pill border / highlighter
-- rectangle). For `minimal`, accent color is ignored.
--
-- `avatar_cutout_url` is populated when the user first picks
-- `bust` — we run the avatar through FAL background removal,
-- upload the cutout PNG to Supabase Storage, store the URL here.
-- Persists across style swaps so a user toggling between styles
-- doesn't pay for repeated bg removal. Cleared when the user
-- changes their avatar (the new avatar's cutout is re-generated
-- on demand if/when they pick `bust` again).

alter table public.profiles
    add column if not exists header_style text not null default 'minimal'
        check (header_style in ('minimal', 'curved', 'bust')),
    add column if not exists header_accent_color text,
    add column if not exists avatar_cutout_url text;
