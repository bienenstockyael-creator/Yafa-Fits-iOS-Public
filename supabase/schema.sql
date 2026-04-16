-- ============================================
-- Yael Fits iOS Public — Database Schema
-- Run this in Supabase Dashboard → SQL Editor
-- ============================================

create extension if not exists pgcrypto;

-- 1. PROFILES (extends auth.users)
create table public.profiles (
  id uuid references auth.users(id) on delete cascade primary key,
  username text unique,
  display_name text,
  avatar_url text,
  bio text,
  created_at timestamptz default now() not null
);

alter table public.profiles enable row level security;

create policy "Public profiles are viewable by everyone"
  on public.profiles for select using (true);

create policy "Users can update own profile"
  on public.profiles for update using (auth.uid() = id);

create policy "Users can insert own profile"
  on public.profiles for insert with check (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)));
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2. OUTFITS
create table public.outfits (
  id text primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  name text not null,
  date date not null,
  frame_count int not null default 242,
  folder text not null,
  prefix text not null,
  frame_ext text default 'webp',
  scale double precision default 1.0,
  is_rotation_reversed boolean default false,
  tags text[] default '{}',
  activity text,
  weather_temp_f int,
  weather_temp_c int,
  weather_condition text,
  is_public boolean default false,
  created_at timestamptz default now() not null
);

alter table public.outfits enable row level security;

create policy "Public outfits viewable by everyone"
  on public.outfits for select using (is_public or auth.uid() = user_id);

create policy "Users can insert own outfits"
  on public.outfits for insert with check (auth.uid() = user_id);

create policy "Users can update own outfits"
  on public.outfits for update using (auth.uid() = user_id);

create policy "Users can delete own outfits"
  on public.outfits for delete using (auth.uid() = user_id);

-- 3. OUTFIT PRODUCTS
create table public.outfit_products (
  id bigint generated always as identity primary key,
  outfit_id text references public.outfits(id) on delete cascade not null,
  name text not null,
  price text,
  image text
);

alter table public.outfit_products enable row level security;

create policy "Products viewable if outfit is viewable"
  on public.outfit_products for select using (
    exists (
      select 1 from public.outfits
      where outfits.id = outfit_products.outfit_id
        and (outfits.is_public or auth.uid() = outfits.user_id)
    )
  );

create policy "Users can manage products on own outfits"
  on public.outfit_products for insert with check (
    exists (
      select 1 from public.outfits
      where outfits.id = outfit_products.outfit_id
        and auth.uid() = outfits.user_id
    )
  );

create policy "Users can delete products on own outfits"
  on public.outfit_products for delete using (
    exists (
      select 1 from public.outfits
      where outfits.id = outfit_products.outfit_id
        and auth.uid() = outfits.user_id
    )
  );

-- 4. LIKES
create table public.likes (
  user_id uuid references public.profiles(id) on delete cascade not null,
  outfit_id text references public.outfits(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (user_id, outfit_id)
);

alter table public.likes enable row level security;

create policy "Likes are viewable by everyone"
  on public.likes for select using (true);

create policy "Users can like"
  on public.likes for insert with check (auth.uid() = user_id);

create policy "Users can unlike"
  on public.likes for delete using (auth.uid() = user_id);

-- 5. SAVES (bookmarks)
create table public.saves (
  user_id uuid references public.profiles(id) on delete cascade not null,
  outfit_id text references public.outfits(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (user_id, outfit_id)
);

alter table public.saves enable row level security;

create policy "Users can see own saves"
  on public.saves for select using (auth.uid() = user_id);

create policy "Users can save"
  on public.saves for insert with check (auth.uid() = user_id);

create policy "Users can unsave"
  on public.saves for delete using (auth.uid() = user_id);

-- 6. COMMENTS
create table public.comments (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  outfit_id text references public.outfits(id) on delete cascade not null,
  body text not null,
  created_at timestamptz default now() not null
);

alter table public.comments enable row level security;

create policy "Comments viewable on public outfits"
  on public.comments for select using (
    exists (
      select 1 from public.outfits
      where outfits.id = comments.outfit_id
        and (outfits.is_public or auth.uid() = outfits.user_id)
    )
  );

create policy "Users can comment"
  on public.comments for insert with check (auth.uid() = user_id);

create policy "Users can delete own comments"
  on public.comments for delete using (auth.uid() = user_id);

-- 7. FOLLOWS
create table public.follows (
  follower_id uuid references public.profiles(id) on delete cascade not null,
  following_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamptz default now() not null,
  primary key (follower_id, following_id),
  check (follower_id != following_id)
);

alter table public.follows enable row level security;

create policy "Follows are viewable by everyone"
  on public.follows for select using (true);

create policy "Users can follow"
  on public.follows for insert with check (auth.uid() = follower_id);

create policy "Users can unfollow"
  on public.follows for delete using (auth.uid() = follower_id);

-- 8. USEFUL VIEWS

-- Like counts per outfit
create or replace view public.outfit_like_counts as
  select outfit_id, count(*) as like_count
  from public.likes
  group by outfit_id;

-- Comment counts per outfit
create or replace view public.outfit_comment_counts as
  select outfit_id, count(*) as comment_count
  from public.comments
  group by outfit_id;

-- Follower/following counts per user
create or replace view public.follow_counts as
  select
    p.id as user_id,
    coalesce(ers.cnt, 0) as follower_count,
    coalesce(ing.cnt, 0) as following_count
  from public.profiles p
  left join (select following_id, count(*) as cnt from public.follows group by following_id) ers
    on ers.following_id = p.id
  left join (select follower_id, count(*) as cnt from public.follows group by follower_id) ing
    on ing.follower_id = p.id;

-- 9. INDEXES
create index idx_outfits_user_id on public.outfits(user_id);
create index idx_outfits_date on public.outfits(date desc);
create index idx_outfits_public on public.outfits(is_public) where is_public = true;
create index idx_likes_outfit on public.likes(outfit_id);
create index idx_comments_outfit on public.comments(outfit_id);
create index idx_follows_following on public.follows(following_id);
create index idx_outfits_tags on public.outfits using gin(tags);

-- 10. SERVER-SIDE GENERATION

alter table public.outfits
  add column if not exists remote_base_url text;

create table if not exists public.generation_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade not null,
  outfit_num integer not null,
  prompt text not null,
  source_image_path text not null,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'complete', 'failed', 'cancelled')),
  review_state text not null default 'pending'
    check (review_state in ('pending', 'accepted', 'published', 'rejected')),
  stage text default 'upload'
    check (stage in ('upload', 'removing_background', 'creating_interactive_fit', 'compressing', 'complete', 'failed')),
  status_title text,
  status_detail text,
  progress double precision,
  error text,
  remote_outfit jsonb,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  completed_at timestamptz
);

create or replace function public.touch_generation_job_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists generation_jobs_touch_updated_at on public.generation_jobs;
create trigger generation_jobs_touch_updated_at
  before update on public.generation_jobs
  for each row execute function public.touch_generation_job_updated_at();

alter table public.generation_jobs enable row level security;

create policy "Users can view own generation jobs"
  on public.generation_jobs for select using (auth.uid() = user_id);

create policy "Users can create own generation jobs"
  on public.generation_jobs for insert with check (auth.uid() = user_id);

create policy "Users can update own pending generation jobs"
  on public.generation_jobs for update using (auth.uid() = user_id);

create index if not exists idx_generation_jobs_user_created_at
  on public.generation_jobs(user_id, created_at desc);

create index if not exists idx_generation_jobs_user_review_state
  on public.generation_jobs(user_id, review_state, created_at desc);

create table if not exists public.device_push_tokens (
  token text primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  platform text not null default 'ios',
  environment text not null default 'production',
  bundle_identifier text not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null
);

create or replace function public.touch_device_push_token_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists device_push_tokens_touch_updated_at on public.device_push_tokens;
create trigger device_push_tokens_touch_updated_at
  before update on public.device_push_tokens
  for each row execute function public.touch_device_push_token_updated_at();

alter table public.device_push_tokens enable row level security;

create policy "Users can view own device push tokens"
  on public.device_push_tokens for select using (auth.uid() = user_id);

create policy "Users can create own device push tokens"
  on public.device_push_tokens for insert with check (auth.uid() = user_id);

create policy "Users can update own device push tokens"
  on public.device_push_tokens for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create index if not exists idx_device_push_tokens_user_updated_at
  on public.device_push_tokens(user_id, updated_at desc);

insert into storage.buckets (id, name, public)
values
  ('generation-inputs', 'generation-inputs', false),
  ('generated-outfits', 'generated-outfits', true)
on conflict (id) do nothing;

create policy "Users can upload own generation inputs"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'generation-inputs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "Users can view own generation inputs"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'generation-inputs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

-- Add remote_base_url and caption to outfits (missing from initial schema)
alter table public.outfits add column if not exists remote_base_url text;
alter table public.outfits add column if not exists caption text;
