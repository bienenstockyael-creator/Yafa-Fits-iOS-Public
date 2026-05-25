-- 3D generation credit system.
--
-- Design summary (see project_yafa_2d_3d_split memory for full context):
--
-- * Free users get 3 free 3D generations per rolling 30 days. Paid users
--   can buy individual $1 credits (separate non-expiring bucket). Pro
--   users have unlimited 3D — they skip the credit accounting entirely
--   but still carry an audit marker on their generation_jobs row.
--
-- * Credit lifecycle: reserve -> (commit | release). A credit is debited
--   from the balance at RESERVE time (so concurrent uploads can't double-
--   spend the last credit). It's only confirmed consumed on COMMIT
--   (user taps Accept on the review screen). On RELEASE (reject, cancel,
--   pipeline failure), the credit is refunded to the bucket it came from.
--
-- * The "credit_source" column on generation_jobs records which bucket
--   was used ('free' / 'paid' / 'pro' / NULL for un-reserved or 2D jobs).
--   This is the single source of truth for refunds — release() refunds
--   to whichever bucket the source says.
--
-- * Rolling 30-day window: when free balance drops below 3 for the first
--   time, gen_credits_reset_at is set to now() + 30 days. The window is
--   cleared either by reserve() detecting it's past the reset time (and
--   refilling balance to 3), or by release() returning balance to 3
--   (no in-flight or consumed credits → no clock).

-- ============================================================
-- Columns
-- ============================================================

alter table public.profiles
  add column if not exists gen_credits_free_balance int not null default 3;

alter table public.profiles
  add column if not exists gen_credits_paid_balance int not null default 0;

alter table public.profiles
  add column if not exists gen_credits_reset_at timestamptz;

alter table public.generation_jobs
  add column if not exists credit_source text
  check (credit_source in ('free', 'paid', 'pro'));

-- ============================================================
-- Helper: refresh free credits if past reset window
-- ============================================================

-- Called at the start of reserve(). If the user's reset clock has
-- elapsed, refill free balance to 3 and clear the clock. No-op
-- otherwise. Security definer so it can update profiles regardless of
-- the caller's RLS context.
create or replace function public.refresh_free_credits_if_due(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
begin
  update public.profiles
  set
    gen_credits_free_balance = 3,
    gen_credits_reset_at = null
  where id = p_user_id
    and gen_credits_reset_at is not null
    and now() > gen_credits_reset_at;
end;
$func$;

-- ============================================================
-- RPC: reserve_3d_credit
-- ============================================================

-- Idempotent. Reserves a credit for the given generation_jobs row.
-- Returns the credit source ('free' / 'paid' / 'pro' / 'none').
-- 'none' means the user is out of credits and the upload flow should
-- route to the paywall.
--
-- Locks the profile row FOR UPDATE while inspecting balances, so two
-- concurrent reserves from the same user can't both consume the last
-- credit.
create or replace function public.reserve_3d_credit(p_job_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_user_id uuid;
  v_existing text;
  v_is_pro boolean;
  v_free int;
  v_paid int;
  v_source text;
begin
  select user_id, credit_source
  into v_user_id, v_existing
  from public.generation_jobs
  where id = p_job_id;

  if v_user_id is null then
    raise exception 'generation_jobs row % not found', p_job_id;
  end if;
  if v_user_id <> auth.uid() then
    raise exception 'not allowed';
  end if;

  -- Idempotent: re-reserving an already-reserved job returns the
  -- existing source without double-charging.
  if v_existing is not null then
    return v_existing;
  end if;

  -- Roll the 30-day window if it's elapsed.
  perform public.refresh_free_credits_if_due(v_user_id);

  -- Pro shortcut: unlimited 3D, no balance change.
  select coalesce(is_pro, false)
  into v_is_pro
  from public.profiles
  where id = v_user_id;

  if v_is_pro then
    update public.generation_jobs
    set credit_source = 'pro'
    where id = p_job_id;
    return 'pro';
  end if;

  -- Lock the profile row, then decide which bucket to charge.
  select gen_credits_free_balance, gen_credits_paid_balance
  into v_free, v_paid
  from public.profiles
  where id = v_user_id
  for update;

  if v_free > 0 then
    update public.profiles
    set
      gen_credits_free_balance = gen_credits_free_balance - 1,
      -- Start the 30-day clock on the first free consumption in a window.
      gen_credits_reset_at = coalesce(gen_credits_reset_at, now() + interval '30 days')
    where id = v_user_id;
    v_source := 'free';
  elsif v_paid > 0 then
    update public.profiles
    set gen_credits_paid_balance = gen_credits_paid_balance - 1
    where id = v_user_id;
    v_source := 'paid';
  else
    return 'none';
  end if;

  update public.generation_jobs
  set credit_source = v_source
  where id = p_job_id;

  return v_source;
end;
$func$;

-- ============================================================
-- RPC: commit_3d_credit
-- ============================================================

-- Called when the user taps Accept on the review screen. No balance
-- change — credit was already debited at reserve time. We keep
-- credit_source set on the job so the audit trail clearly shows
-- which bucket was consumed.
--
-- This RPC exists more for symmetry / future use than necessity — it
-- gives us a clear "commit" call site if we ever want to add per-commit
-- analytics, telemetry, or post-commit hooks.
create or replace function public.commit_3d_credit(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_user_id uuid;
begin
  select user_id
  into v_user_id
  from public.generation_jobs
  where id = p_job_id;

  if v_user_id is null then
    raise exception 'generation_jobs row % not found', p_job_id;
  end if;
  if v_user_id <> auth.uid() then
    raise exception 'not allowed';
  end if;
  -- No balance change; reserve already debited.
end;
$func$;

-- ============================================================
-- RPC: release_3d_credit
-- ============================================================

-- Refunds a previously-reserved credit. Called on user Reject, Cancel,
-- or any pipeline failure (Kling timeout, FAL error, etc.). Refunds to
-- the SAME bucket the credit was reserved from (per credit_source).
--
-- Idempotent: clearing credit_source means a second release call no-ops.
-- For 'pro', no balance change is needed since Pro doesn't consume from
-- any bucket.
--
-- After refunding 'free' credits, if the user's free balance is back at
-- 3 we clear gen_credits_reset_at — there are no credits in flight or
-- consumed, so the 30-day clock shouldn't keep running.
create or replace function public.release_3d_credit(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_user_id uuid;
  v_source text;
begin
  select user_id, credit_source
  into v_user_id, v_source
  from public.generation_jobs
  where id = p_job_id;

  if v_user_id is null then
    raise exception 'generation_jobs row % not found', p_job_id;
  end if;
  if v_user_id <> auth.uid() then
    raise exception 'not allowed';
  end if;
  if v_source is null then
    return;
  end if;

  if v_source = 'free' then
    update public.profiles
    set gen_credits_free_balance = gen_credits_free_balance + 1
    where id = v_user_id;
    update public.profiles
    set gen_credits_reset_at = null
    where id = v_user_id
      and gen_credits_free_balance >= 3;
  elsif v_source = 'paid' then
    update public.profiles
    set gen_credits_paid_balance = gen_credits_paid_balance + 1
    where id = v_user_id;
  end if;
  -- 'pro' source: no balance change.

  update public.generation_jobs
  set credit_source = null
  where id = p_job_id;
end;
$func$;

-- ============================================================
-- Permissions
-- ============================================================

grant execute on function public.refresh_free_credits_if_due(uuid) to authenticated;
grant execute on function public.reserve_3d_credit(uuid) to authenticated;
grant execute on function public.commit_3d_credit(uuid) to authenticated;
grant execute on function public.release_3d_credit(uuid) to authenticated;
