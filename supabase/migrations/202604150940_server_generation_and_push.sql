create extension if not exists pgcrypto;

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

drop policy if exists "Users can view own generation jobs" on public.generation_jobs;
create policy "Users can view own generation jobs"
  on public.generation_jobs for select using (auth.uid() = user_id);

drop policy if exists "Users can create own generation jobs" on public.generation_jobs;
create policy "Users can create own generation jobs"
  on public.generation_jobs for insert with check (auth.uid() = user_id);

drop policy if exists "Users can update own pending generation jobs" on public.generation_jobs;
create policy "Users can update own pending generation jobs"
  on public.generation_jobs for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

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

drop policy if exists "Users can view own device push tokens" on public.device_push_tokens;
create policy "Users can view own device push tokens"
  on public.device_push_tokens for select using (auth.uid() = user_id);

drop policy if exists "Users can create own device push tokens" on public.device_push_tokens;
create policy "Users can create own device push tokens"
  on public.device_push_tokens for insert with check (auth.uid() = user_id);

drop policy if exists "Users can update own device push tokens" on public.device_push_tokens;
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

drop policy if exists "Users can upload own generation inputs" on storage.objects;
create policy "Users can upload own generation inputs"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'generation-inputs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

drop policy if exists "Users can view own generation inputs" on storage.objects;
create policy "Users can view own generation inputs"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'generation-inputs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
