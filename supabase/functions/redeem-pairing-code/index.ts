// Redeem a browser-extension pairing code for a Supabase session.
//
// The extension has no session (that's the whole point of pairing). It POSTs a
// short code the user generated in the app; this function (service role)
// atomically claims the code (single-use, unexpired), then mints a session for
// THAT user via admin.generateLink + verifyOtp, and returns it. The
// service-role key never leaves the server; the extension only ever holds the
// resulting user session + the public anon key.
//
// Required env (auto-provided by the Edge Runtime):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy redeem-pairing-code --no-verify-jwt
//   (--no-verify-jwt: the caller is unauthenticated by design.)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json(500, { error: "misconfigured" });
  }

  let code: string;
  try {
    const body = await req.json();
    code = String(body?.code ?? "").trim().toUpperCase();
  } catch {
    return json(400, { error: "bad_request" });
  }
  if (!/^[A-Z0-9]{6,12}$/.test(code)) return json(400, { error: "invalid_code" });

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Atomically claim the code — the update only matches a row that is still
  // unconsumed and unexpired, so a code can never be redeemed twice (even
  // under a race) and expired codes are rejected.
  const { data: claimed, error: claimErr } = await admin
    .from("pairing_codes")
    .update({ consumed_at: new Date().toISOString() })
    .eq("code", code)
    .is("consumed_at", null)
    .gt("expires_at", new Date().toISOString())
    .select("user_id")
    .maybeSingle();

  if (claimErr) return json(500, { error: "claim_failed" });
  if (!claimed) return json(400, { error: "invalid_or_expired_code" });

  // Look up the user's email (Apple sign-in stores a relay email here).
  const { data: userData, error: userErr } = await admin.auth.admin.getUserById(
    claimed.user_id,
  );
  const email = userData?.user?.email;
  if (userErr || !email) return json(500, { error: "user_lookup_failed" });

  // Mint a one-time magic-link token (NOT emailed — generateLink just returns
  // it), then exchange it for a real session server-side.
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email,
  });
  const tokenHash = (link as { properties?: { hashed_token?: string } })?.properties?.hashed_token;
  if (linkErr || !tokenHash) return json(500, { error: "link_failed" });

  const anon = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: verified, error: verifyErr } = await anon.auth.verifyOtp({
    type: "magiclink",
    token_hash: tokenHash,
  });
  const session = verified?.session;
  if (verifyErr || !session) return json(500, { error: "session_failed" });

  return json(200, {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_at: session.expires_at,
    user_id: claimed.user_id,
  });
});
