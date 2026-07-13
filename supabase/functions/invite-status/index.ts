// Public lookup for the invite web card: given a code, return its
// state and the inviter's public profile so the page can render
// "@yael invited you to Yafa" and flip to reveal (or show who
// claimed it). No auth — the web visitor has no session yet.
//
// Deliberately reveals nothing beyond what the card must show:
// - invalid codes and manual (non-invite) codes both return
//   { state: "invalid" } — the endpoint can't be used to probe
//   Yael's hand-minted codes.
// - only public profile fields (username/display_name/avatar_url),
//   which the profiles SELECT policy already exposes to everyone.
//
// Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// Deploy: supabase functions deploy invite-status --project-ref dqvwutzoakfmnhbsefsw

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
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return json(500, { error: "misconfigured" });

  let code = "";
  try {
    const body = await req.json();
    code = String(body?.code ?? "").trim().toUpperCase();
  } catch {
    return json(400, { error: "bad_request" });
  }
  // Minted invite codes are exactly YAFA-XXXX; reject everything else
  // before touching the DB (also keeps manual codes unprobeable).
  if (!/^YAFA-[A-Z2-9]{4}$/.test(code)) return json(200, { state: "invalid" });

  const admin = createClient(supabaseUrl, serviceRoleKey);

  const { data: row, error } = await admin
    .from("access_codes")
    .select("code, inviter_id, redeemed_by, redeemed_at")
    .eq("code", code)
    .maybeSingle();
  if (error) return json(500, { error: "lookup_failed" });
  // Only owner-minted codes are invite cards.
  if (!row || !row.inviter_id) return json(200, { state: "invalid" });

  const ids = [row.inviter_id, row.redeemed_by].filter(Boolean) as string[];
  const { data: profiles } = await admin
    .from("profiles")
    .select("id, username, display_name, avatar_url")
    .in("id", ids);
  const byId = new Map((profiles ?? []).map((p) => [p.id, p]));
  const pub = (id: string | null) => {
    const p = id ? byId.get(id) : null;
    return p
      ? { username: p.username, display_name: p.display_name, avatar_url: p.avatar_url }
      : null;
  };

  if (row.redeemed_by) {
    return json(200, {
      state: "redeemed",
      inviter: pub(row.inviter_id),
      claimed_by: pub(row.redeemed_by),
      redeemed_at: row.redeemed_at,
    });
  }
  return json(200, { state: "active", inviter: pub(row.inviter_id), code: row.code });
});
