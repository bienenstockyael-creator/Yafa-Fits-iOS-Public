// Mint a dedicated, independent session for the iOS Share Extension.
//
// The share extension can't safely share the app's own session: if both the
// app and the extension held the same refresh token and either one rotated it,
// the other would silently get logged out. So instead the *app* (already
// signed in) calls this function, which mints a SEPARATE session for the same
// user via admin.generateLink + verifyOtp — exactly the redeem-pairing-code
// trick, but the caller is the authenticated app rather than an unpaired
// browser. The app stows the result in the shared App Group; the extension
// uses + refreshes that on its own without ever touching the app's login.
//
// Required env (auto-provided by the Edge Runtime):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy mint-extension-session
//   (Verify JWT ON — the caller is the authenticated app.)

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

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { error: "missing_auth" });

  // Identify the caller from their (app) session.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json(401, { error: "invalid_auth" });

  const email = user.email;
  if (!email) return json(500, { error: "user_has_no_email" });

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Mint a one-time magic-link token (NOT emailed — generateLink just returns
  // it), then exchange it for a real, independent session server-side.
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
    user_id: user.id,
  });
});
