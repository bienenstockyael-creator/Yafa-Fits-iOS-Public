-- Pairing codes: link a browser extension to a Yafa account.
--
-- The signed-in app creates a short-lived, single-use code and shows it. The
-- extension (which has no session) redeems it through the `redeem-pairing-code`
-- edge function, which runs as service-role, validates the code, mints a
-- session for that user, and marks the code consumed. So there is NO public
-- read/update of this table — only the owner can create/see their own codes;
-- redemption is server-side only.

create extension if not exists pgcrypto;

-- Cryptographically-random 8-char code from an unambiguous alphabet
-- (no 0/O/1/I/L) so it's easy to read off a phone and type.
create or replace function public.gen_pairing_code()
returns text
language plpgsql
as $func$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea := gen_random_bytes(8);
  result text := '';
  i int;
begin
  for i in 0..7 loop
    result := result || substr(alphabet, 1 + (get_byte(bytes, i) % length(alphabet)), 1);
  end loop;
  return result;
end;
$func$;

create table if not exists public.pairing_codes (
  code        text primary key default public.gen_pairing_code(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default (now() + interval '10 minutes'),
  consumed_at timestamptz
);

create index if not exists pairing_codes_user_idx on public.pairing_codes(user_id);
create index if not exists pairing_codes_expires_idx on public.pairing_codes(expires_at);

alter table public.pairing_codes enable row level security;

-- The signed-in user may create a code for themselves and read it back to show
-- it. They cannot read anyone else's, and nobody can update/delete via the API.
create policy "pairing_codes_owner_insert" on public.pairing_codes
  for insert to authenticated with check (user_id = auth.uid());

create policy "pairing_codes_owner_select" on public.pairing_codes
  for select to authenticated using (user_id = auth.uid());

-- (Redemption is performed only by the service-role edge function, which
--  bypasses RLS. No anon/authenticated update, delete, or cross-user select.)
