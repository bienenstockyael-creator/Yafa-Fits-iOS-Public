// Generates (once) a transparent "bust" cut-out for a user who appears on the
// vibes leaderboard but hasn't made one themselves, and persists it to their
// profile so it's cached forever and makes their whole profile bust-ready.
//
// Idempotent: if the target already has avatar_cutout_url, it's returned as-is
// (no FAL call). The caller must be authenticated, but the write uses the
// service role since we're updating ANOTHER user's profile row (RLS only lets a
// user edit their own).
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";

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

const FAL_BASE = "https://queue.fal.run/";
const POLL_MS = 2500;
const MAX_POLLS = 60; // ~150s ceiling, within the edge timeout
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function dataUriFromUrl(url: string): Promise<string> {
  const r = await fetch(url);
  if (!r.ok) throw new Error("image_fetch_failed");
  const type = r.headers.get("content-type") || "image/jpeg";
  const bytes = new Uint8Array(await r.arrayBuffer());
  return `data:${type};base64,${encodeBase64(bytes)}`;
}

// Submit a FAL queue job and poll until it completes; return the result JSON.
async function falRun(modelPath: string, body: unknown, falKey: string): Promise<any> {
  const auth = { Authorization: `Key ${falKey}`, Accept: "application/json" };
  const submit = await fetch(FAL_BASE + modelPath, {
    method: "POST",
    headers: { ...auth, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!submit.ok) throw new Error(`fal_submit_failed_${submit.status}`);
  const { status_url, response_url } = await submit.json();

  for (let i = 0; i < MAX_POLLS; i++) {
    await sleep(POLL_MS);
    const st = await fetch(status_url, { headers: auth });
    const sd = await st.json();
    const status = String(sd?.status ?? "").toLowerCase();
    if (status === "completed") {
      const res = await fetch(response_url, { headers: auth });
      return await res.json();
    }
    if (status === "failed" || status === "error") throw new Error("fal_job_failed");
  }
  throw new Error("fal_timeout");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const falKey = Deno.env.get("FAL_API_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey || !falKey) return json(500, { error: "misconfigured" });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { error: "missing_auth" });

  // Caller must be signed in (any signed-in user can request a bust for a
  // leaderboard member) — but the WRITE uses the service role.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json(401, { error: "invalid_auth" });

  let body: { user_id?: string };
  try { body = await req.json(); } catch { return json(400, { error: "bad_request" }); }
  const targetId = body.user_id;
  if (!targetId) return json(400, { error: "missing_user_id" });

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    // Idempotent: already has a cut-out → return it, no regeneration.
    const { data: profile, error: pErr } = await admin
      .from("profiles")
      .select("avatar_url, avatar_cutout_url")
      .eq("id", targetId)
      .single();
    if (pErr || !profile) return json(404, { error: "profile_not_found" });
    if (profile.avatar_cutout_url) {
      return json(200, { cutout_url: profile.avatar_cutout_url, cached: true });
    }
    if (!profile.avatar_url) return json(200, { cutout_url: null });

    // Background-remove the avatar → transparent bust PNG. (No nano-banana step:
    // the avatar is already a person photo, we just strip the background.)
    const bria = await falRun(
      "fal-ai/bria/background/remove",
      { image_url: await dataUriFromUrl(profile.avatar_url) },
      falKey,
    );
    const briaImg = bria?.image;
    const cutoutUrl = Array.isArray(briaImg) ? briaImg[0]?.url : briaImg?.url;
    if (!cutoutUrl) return json(502, { error: "bria_no_image" });

    const pngResp = await fetch(cutoutUrl);
    if (!pngResp.ok) return json(502, { error: "cutout_fetch_failed" });
    const pngBytes = new Uint8Array(await pngResp.arrayBuffer());

    // Store in the avatars bucket (same scheme the app uses for cut-outs).
    const path = `${targetId}/cutout-auto-${Date.now()}.png`;
    const { error: upErr } = await admin.storage
      .from("avatars")
      .upload(path, pngBytes, { contentType: "image/png", upsert: false });
    if (upErr) return json(500, { error: "upload_failed", detail: upErr.message });
    const publicUrl = admin.storage.from("avatars").getPublicUrl(path).data.publicUrl;

    // Persist to the target's profile (service role bypasses RLS).
    const { error: updErr } = await admin
      .from("profiles")
      .update({ avatar_cutout_url: publicUrl })
      .eq("id", targetId);
    if (updErr) return json(500, { error: "profile_update_failed", detail: updErr.message });

    return json(200, { cutout_url: publicUrl, cached: false });
  } catch (e) {
    return json(502, { error: "ensure_bust_failed", detail: String((e as Error)?.message ?? e) });
  }
});
