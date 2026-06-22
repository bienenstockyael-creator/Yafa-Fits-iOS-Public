-- UGC moderation: blocks + reports (App Store Guideline 1.2).
--
-- A user-generated-content app (public feed, comments) must let users
-- (1) block abusive users and (2) report objectionable content. These
-- two tables back both. Moderation/action on reports happens via the
-- service role (dashboard or future tooling) — clients can file and
-- read their own reports but never edit or delete them.

-- ============================================================
-- blocks: who has blocked whom
-- ============================================================
-- The blocker's app fetches its own block list and filters blocked
-- users out of the feed, comments, and follow lists client-side. The
-- SELECT policy only exposes a user's OWN blocks, so a blocked user
-- can never tell that they've been blocked.
create table public.blocks (
  blocker_id uuid references public.profiles(id) on delete cascade not null,
  blocked_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (blocker_id, blocked_id),
  -- Can't block yourself.
  constraint blocks_no_self check (blocker_id <> blocked_id)
);

alter table public.blocks enable row level security;

create policy "Users see own blocks"
  on public.blocks for select using (auth.uid() = blocker_id);

create policy "Users can block"
  on public.blocks for insert with check (auth.uid() = blocker_id);

create policy "Users can unblock"
  on public.blocks for delete using (auth.uid() = blocker_id);

-- ============================================================
-- reports: flagged outfits / comments / users
-- ============================================================
-- content_type says what was reported; the matching reported_* column
-- carries the target id (set null on cascade so a report survives the
-- content being deleted, preserving the moderation trail). reason is a
-- short category from the app; details is optional free text.
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete cascade not null,
  content_type text not null check (content_type in ('outfit', 'comment', 'user')),
  reported_user_id uuid references public.profiles(id) on delete set null,
  reported_outfit_id text references public.outfits(id) on delete set null,
  reported_comment_id bigint references public.comments(id) on delete set null,
  reason text,
  details text,
  status text not null default 'pending'
    check (status in ('pending', 'reviewed', 'actioned', 'dismissed')),
  created_at timestamptz default now() not null
);

alter table public.reports enable row level security;

-- Clients can file a report and see the ones they filed. No client
-- UPDATE/DELETE — reports are append-only from the app; moderation is
-- service-role only.
create policy "Users can report"
  on public.reports for insert with check (auth.uid() = reporter_id);

create policy "Reporters see own reports"
  on public.reports for select using (auth.uid() = reporter_id);

-- Moderation queue: pending reports, newest first.
create index reports_status_created_idx
  on public.reports (status, created_at desc);
