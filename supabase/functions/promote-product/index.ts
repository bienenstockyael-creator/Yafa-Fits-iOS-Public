// Promote a raw saved product (from the browser extension) into the user's
// Yafa closet, with a polished thumbnail that matches the app.
//
// Runs the SAME pipeline as the app's Quick-Add: nano-banana/edit isolates the
// item into a clean studio shot, then Bria removes the background. The cutout
// is uploaded to the `products` storage bucket and a `products` row is inserted
// under the caller's account.
//
// Auth: caller must pass a valid user session (Authorization: Bearer ...),
// which the extension obtained via pairing. FAL_API_KEY stays server-side.
//
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY, FAL_API_KEY
// Deploy: supabase functions deploy promote-product

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

function nanoPrompt(item: string): string {
  const it = item && item.trim() ? item.trim() : "item";
  return [
    `Generate a professional flat-lay e-commerce product photograph of the ${it} shown in the input image.`,
    `Isolate just that single item — the ${it} — as a clean catalog product shot.`,
    `Remove any model, body, skin, hair, hands, background, props, and any other item that is not the ${it}.`,
    `Lay the item flat or place it on an invisible mannequin. Studio lighting, clean white background.`,
    `Reproduce the exact ${it} from the input — same colour, fabric, cut, length, sleeve length, neckline, silhouette, and visible details.`,
    `Do not add features (hood, collar, pockets, zippers, buttons, prints, patterns) that are not clearly visible on the ${it} in the input.`,
    `Do not change the item's colour, length, sleeve length, neckline, or silhouette.`,
    `Orient the item right-side-up: the top at the top, the bottom at the bottom. Never output a rotated, upside-down, or sideways image.`,
  ].join(" ");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const falKey = Deno.env.get("FAL_API_KEY");
  if (!supabaseUrl || !anonKey || !falKey) return json(500, { error: "misconfigured" });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { error: "missing_auth" });

  // Identify the caller from their session.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return json(401, { error: "invalid_auth" });

  let p: { name?: string; image_url?: string; source_url?: string; price?: string; brand?: string; category?: string };
  try {
    p = await req.json();
  } catch {
    return json(400, { error: "bad_request" });
  }
  if (!p.image_url) return json(400, { error: "missing_image" });

  try {
    // 1. Raw retailer image → data URI (server-side fetch dodges hotlink/CORS).
    const rawDataUri = await dataUriFromUrl(p.image_url);

    // 2. nano-banana: isolate the item into a clean studio shot.
    const nano = await falRun(
      "fal-ai/nano-banana/edit",
      { prompt: nanoPrompt(p.name ?? ""), image_urls: [rawDataUri] },
      falKey,
    );
    const nanoUrl = nano?.images?.[0]?.url;
    if (!nanoUrl) return json(502, { error: "nano_no_image" });

    // 3. Bria: remove the white background → transparent PNG.
    const bria = await falRun(
      "fal-ai/bria/background/remove",
      { image_url: await dataUriFromUrl(nanoUrl) },
      falKey,
    );
    const briaImg = bria?.image;
    const cutoutUrl = Array.isArray(briaImg) ? briaImg[0]?.url : briaImg?.url;
    if (!cutoutUrl) return json(502, { error: "bria_no_image" });

    const pngResp = await fetch(cutoutUrl);
    if (!pngResp.ok) return json(502, { error: "cutout_fetch_failed" });
    const pngBytes = new Uint8Array(await pngResp.arrayBuffer());

    // 4. Upload to the `products` bucket (same path scheme as the app).
    const path = `${user.id}/auto-${Date.now()}.png`;
    const { error: upErr } = await userClient.storage
      .from("products")
      .upload(path, pngBytes, { contentType: "image/png", upsert: false });
    if (upErr) return json(500, { error: "upload_failed", detail: upErr.message });
    const imageUrl = userClient.storage.from("products").getPublicUrl(path).data.publicUrl;

    // 5. Insert the polished closet product (wishlist — a shopping find).
    const { data: inserted, error: insErr } = await userClient
      .from("products")
      .insert({
        user_id: user.id,
        name: p.name ?? "Item",
        image_url: imageUrl,
        category: p.category ?? "unknown",
        brand: p.brand ?? null,
        price: p.price ?? null,
        source_url: p.source_url ?? null,
        status: "wishlist",
        tags: [],
      })
      .select("id")
      .single();
    if (insErr) return json(500, { error: "insert_failed", detail: insErr.message });

    return json(200, { product_id: inserted.id, image_url: imageUrl, status: "wishlist" });
  } catch (e) {
    return json(502, { error: "promote_failed", detail: String((e as Error)?.message ?? e) });
  }
});
