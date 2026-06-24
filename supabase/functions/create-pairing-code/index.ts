// Create a browser-extension pairing code for the signed-in user.
//
// Runs as service-role so it can insert the row regardless of RLS, but it
// sets user_id to the VERIFIED caller (from their JWT) — never a client-
// supplied id — so a code can only ever be created for your own account.
// Returns { code, expires_at } (the DB generates both).
//
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
// Deploy: supabase functions deploy create-pairing-code

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
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json(500, { error: "misconfigured" });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { error: "missing_auth" });

  // Identify the caller from their session.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json(401, { error: "invalid_auth" });

  // Insert as service-role with the verified user id.
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await admin
    .from("pairing_codes")
    .insert({ user_id: user.id })
    .select("code, expires_at")
    .single();
  if (error || !data) return json(500, { error: "insert_failed", detail: error?.message });

  return json(200, { code: data.code, expires_at: data.expires_at });
});
