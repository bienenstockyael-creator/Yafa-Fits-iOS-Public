-- Social push notifications: DB triggers that call the send-push edge
-- function when someone likes / vibes / comments on a fit.
--
-- BEFORE RUNNING, replace the two placeholders in notify_push():
--   __PUSH_SECRET__  — same value as the PUSH_SECRET function secret
--   __ANON_KEY__     — the project anon key (Settings → API), needed
--                      because edge functions verify a JWT by default
--
-- Requires the pg_net extension (Dashboard → Database → Extensions).

create extension if not exists pg_net;

-- Device tokens table (idempotent — the iOS client has been upserting
-- here already; this guarantees the shape if it was dashboard-created).
create table if not exists public.device_push_tokens (
  token text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  platform text not null default 'ios',
  environment text not null default 'production',
  bundle_identifier text not null default 'com.yafa.Yafa',
  updated_at timestamptz not null default now()
);

alter table public.device_push_tokens enable row level security;

drop policy if exists "own tokens" on public.device_push_tokens;
create policy "own tokens" on public.device_push_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Shared helper: fire-and-forget POST to the edge function.
create or replace function public.notify_push(
  p_kind text,
  p_recipient uuid,
  p_actor uuid,
  p_outfit_id text,
  p_body text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $func$
begin
  -- Self-actions never notify.
  if p_recipient is null or p_actor is null or p_recipient = p_actor then
    return;
  end if;

  perform net.http_post(
    url := 'https://dqvwutzoakfmnhbsefsw.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer __ANON_KEY__',
      'x-push-secret', '__PUSH_SECRET__'
    ),
    body := jsonb_build_object(
      'kind', p_kind,
      'recipient_id', p_recipient,
      'actor_id', p_actor,
      'outfit_id', p_outfit_id,
      'body', p_body
    )
  );
end;
$func$;

-- LIKE → notify the fit's owner.
create or replace function public.on_like_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_owner uuid;
begin
  select user_id into v_owner from public.outfits where id = new.outfit_id;
  perform public.notify_push('like', v_owner, new.user_id, new.outfit_id);
  return new;
end;
$func$;

drop trigger if exists like_push_notify on public.likes;
create trigger like_push_notify
  after insert on public.likes
  for each row execute function public.on_like_notify();

-- VIBE → receiver is already on the row.
create or replace function public.on_vibe_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $func$
begin
  perform public.notify_push('vibe', new.receiver_id, new.giver_id, new.outfit_id);
  return new;
end;
$func$;

drop trigger if exists vibe_push_notify on public.vibes;
create trigger vibe_push_notify
  after insert on public.vibes
  for each row execute function public.on_vibe_notify();

-- COMMENT → notify the fit's owner, preview the comment body.
create or replace function public.on_comment_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_owner uuid;
begin
  select user_id into v_owner from public.outfits where id = new.outfit_id;
  perform public.notify_push('comment', v_owner, new.user_id, new.outfit_id, new.body);
  return new;
end;
$func$;

drop trigger if exists comment_push_notify on public.comments;
create trigger comment_push_notify
  after insert on public.comments
  for each row execute function public.on_comment_notify();
