-- Paid credit purchases — audit ledger + grant RPC.
--
-- Builds on the existing 3D credit system (see
-- 20260517100000_3d_credit_system.sql). That migration already provides:
--   * `gen_credits_paid_balance` on profiles — the non-expiring "purchased"
--     bucket. This is where IAP purchases land.
--   * reserve / commit / release lifecycle for the SPEND side.
--
-- This migration adds the BUY side:
--   1. `credit_purchases` audit table — append-only record of every
--      successful App Store IAP. UNIQUE on apple_transaction_id is the
--      idempotency guarantee: a duplicate receipt submission (from a
--      retry, an out-of-order Apple callback, etc.) can't double-credit
--      the user.
--   2. `grant_paid_credits` RPC — atomically insert the audit row and
--      bump `gen_credits_paid_balance`. Service-role only, called from
--      the `validate-apple-receipt` Edge Function once Apple's JWS has
--      been verified.
--
-- The audit table also unblocks future work without further migrations:
-- purchase history UI, refund handling (delta-aware), per-tier
-- analytics, fraud / abuse detection on duplicate device patterns.

-- ============================================================
-- Audit table
-- ============================================================

create table if not exists public.credit_purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,

  -- Apple's StoreKit 2 transaction ID. UNIQUE = the idempotency key.
  -- A second call with the same ID returns the existing row instead of
  -- inserting / re-crediting.
  apple_transaction_id text not null unique,

  -- App Store Connect product ID (e.g. 'com.yafa.credits.single',
  -- 'com.yafa.credits.starter'). Stored verbatim so a future audit can
  -- reconstruct exactly which bundle was sold without joining against
  -- a price table.
  product_id text not null,

  -- How many credits this purchase granted. Matches the bundle size on
  -- the iOS side — we trust the Edge Function to map product_id → credits
  -- before calling the RPC so this column is the audit truth.
  credits_granted int not null check (credits_granted > 0),

  -- Price paid in the smallest currency unit (cents for USD). Stored
  -- alongside currency code so future currencies don't require a
  -- schema change.
  price_cents int not null check (price_cents > 0),
  currency text not null default 'USD',

  -- Full Apple receipt / JWS payload kept as JSONB for forensic audit.
  -- Worth the storage cost — when a user disputes a charge or Apple
  -- issues a refund, having the original payload is invaluable.
  receipt_payload jsonb,

  created_at timestamptz not null default now()
);

create index if not exists idx_credit_purchases_user_id
  on public.credit_purchases (user_id, created_at desc);

-- ============================================================
-- RLS — users read own, only service_role writes
-- ============================================================

alter table public.credit_purchases enable row level security;

-- Users can see their own purchase history (e.g. a "your receipts"
-- screen in settings later). They can't insert / update / delete —
-- those paths only run under service_role from the Edge Function
-- after receipt validation.
drop policy if exists "users read own purchases" on public.credit_purchases;
create policy "users read own purchases"
  on public.credit_purchases for select
  to authenticated
  using (auth.uid() = user_id);

-- ============================================================
-- RPC: grant_paid_credits
-- ============================================================

-- Called from the validate-apple-receipt Edge Function under
-- service_role AFTER Apple's JWS signature has been verified.
-- The Edge Function is responsible for:
--   1. Validating the JWS came from Apple.
--   2. Mapping product_id -> credits granted (single source of truth
--      on the server; we don't trust the client to declare bundle
--      size).
--   3. Calling this RPC with the validated user_id + txn metadata.
--
-- Atomicity: the audit insert and the balance bump happen inside one
-- transaction (plpgsql function = implicit txn), so a crash between
-- the two leaves the system consistent — either both committed or
-- neither.
--
-- Idempotency: the UNIQUE constraint on apple_transaction_id is the
-- guard. We check explicitly first so we can return a
-- "was_already_credited" flag, but the UNIQUE constraint is the actual
-- safety net if two concurrent calls race.
create or replace function public.grant_paid_credits(
  p_user_id uuid,
  p_apple_transaction_id text,
  p_product_id text,
  p_credits int,
  p_price_cents int,
  p_currency text default 'USD',
  p_receipt_payload jsonb default null
)
returns json
language plpgsql
security definer
set search_path = public
as $func$
declare
  v_existing uuid;
  v_new_balance int;
begin
  if p_credits is null or p_credits <= 0 then
    raise exception 'p_credits must be positive, got %', p_credits;
  end if;

  -- Idempotency: if we've already credited this transaction, return
  -- the current balance and signal that nothing changed.
  select id into v_existing
  from public.credit_purchases
  where apple_transaction_id = p_apple_transaction_id;

  if v_existing is not null then
    select gen_credits_paid_balance into v_new_balance
    from public.profiles
    where id = p_user_id;

    return json_build_object(
      'new_paid_balance', v_new_balance,
      'was_already_credited', true
    );
  end if;

  -- Append the audit row first. If the user_id doesn't reference a
  -- real auth.users row, the FK fails and the whole txn rolls back —
  -- the balance never gets bumped against a bogus user.
  insert into public.credit_purchases (
    user_id,
    apple_transaction_id,
    product_id,
    credits_granted,
    price_cents,
    currency,
    receipt_payload
  ) values (
    p_user_id,
    p_apple_transaction_id,
    p_product_id,
    p_credits,
    p_price_cents,
    p_currency,
    p_receipt_payload
  );

  -- Bump the non-expiring paid bucket. The existing reserve/commit/
  -- release flow handles spending from here.
  update public.profiles
  set gen_credits_paid_balance = gen_credits_paid_balance + p_credits
  where id = p_user_id
  returning gen_credits_paid_balance into v_new_balance;

  if v_new_balance is null then
    raise exception 'profile not found for user %', p_user_id;
  end if;

  return json_build_object(
    'new_paid_balance', v_new_balance,
    'was_already_credited', false
  );
end;
$func$;

-- ============================================================
-- Permissions
-- ============================================================

-- Service role only — never expose this to `authenticated`. The whole
-- security model relies on Apple's JWS signature being verified server-
-- side BEFORE this RPC is called. Letting a client call it directly
-- would let any authenticated user grant themselves arbitrary credits.
revoke all on function public.grant_paid_credits(uuid, text, text, int, int, text, jsonb) from public;
revoke all on function public.grant_paid_credits(uuid, text, text, int, int, text, jsonb) from authenticated;
revoke all on function public.grant_paid_credits(uuid, text, text, int, int, text, jsonb) from anon;
