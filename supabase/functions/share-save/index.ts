// Save a product to the user's Yafa wishlist from a shared URL (iOS Share
// Extension). The extension only has a URL — it can't read the retailer page
// like the Chrome content script — so we scrape server-side here, insert the
// wishlist row IMMEDIATELY with the raw retailer image (fast response, the
// share sheet can dismiss), then polish the thumbnail in the BACKGROUND with
// the same FAL pipeline as promote-product. The polished cut-out swaps in a
// minute or so later, so by the time the user opens the app it matches the
// closet.
//
// Auth: caller passes the extension's minted user session (Authorization:
// Bearer ...). FAL_API_KEY stays server-side.
//
// Required env: SUPABASE_URL, SUPABASE_ANON_KEY, FAL_API_KEY
// Deploy: supabase functions deploy share-save   (Verify JWT ON)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";

// Supabase Edge Runtime global for running work after the response is sent.
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

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
const MAX_POLLS = 50; // ~125s ceiling, within the background-task budget
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36";

// ---------- Scraping (OpenGraph + JSON-LD + sensible fallbacks) ----------

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .trim();
}

function metaContent(html: string, key: string): string | null {
  // matches <meta property="og:image" content="..."> in either attr order
  const patterns = [
    new RegExp(`<meta[^>]+(?:property|name)=["']${key}["'][^>]+content=["']([^"']+)["']`, "i"),
    new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']${key}["']`, "i"),
  ];
  for (const re of patterns) {
    const m = html.match(re);
    if (m?.[1]) return decodeEntities(m[1]);
  }
  return null;
}

function absolutize(src: string | null, base: string): string | null {
  if (!src) return null;
  // Reject scheme-without-authority values like "https:files/x.jpg" —
  // Cult Gaia's JSON-LD ships exactly this (their Shopify template is
  // broken). new URL() silently resolves it RELATIVE to the page,
  // fabricating a dead same-site path (/products/files/x.jpg) that
  // then gets saved as the wishlist image. Treat it as no value so
  // the caller falls through to og:image, which is well-formed.
  if (/^https?:(?!\/\/)/i.test(src.trim())) return null;
  try {
    return new URL(src, base).toString();
  } catch {
    return src;
  }
}

interface Scraped { name: string; image: string | null; price: string | null; brand: string | null; }

function fromJsonLd(html: string): Partial<Scraped> {
  const out: Partial<Scraped> = {};
  const blocks = [...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
  for (const b of blocks) {
    let parsed: unknown;
    try { parsed = JSON.parse(b[1].trim()); } catch { continue; }
    const nodes: any[] = Array.isArray(parsed) ? parsed : [parsed];
    // also walk @graph arrays
    const flat: any[] = [];
    for (const n of nodes) {
      flat.push(n);
      if (n && Array.isArray(n["@graph"])) flat.push(...n["@graph"]);
    }
    for (const n of flat) {
      const type = n?.["@type"];
      const isProduct = type === "Product" || (Array.isArray(type) && type.includes("Product"));
      if (!isProduct) continue;
      if (!out.name && typeof n.name === "string") out.name = n.name;
      if (!out.image) {
        const img = Array.isArray(n.image) ? n.image[0] : n.image;
        if (typeof img === "string") out.image = img;
        else if (img?.url) out.image = img.url;
      }
      if (!out.brand) {
        const brand = typeof n.brand === "string" ? n.brand : n.brand?.name;
        if (brand) out.brand = brand;
      }
      if (!out.price) {
        const offers = Array.isArray(n.offers) ? n.offers[0] : n.offers;
        const price = offers?.price ?? offers?.priceSpecification?.price;
        const cur = offers?.priceCurrency ?? offers?.priceSpecification?.priceCurrency ?? "";
        if (price != null) out.price = `${cur ? cur + " " : ""}${price}`.trim();
      }
    }
  }
  return out;
}

/// Human-readable fallback name from the product URL's slug —
/// "products/osa-shoulder-bag-natural" → "Osa Shoulder Bag Natural".
function nameFromSlug(url: string): string {
  try {
    const path = new URL(url).pathname;
    const slug = path.split("/").filter(Boolean).pop() ?? "";
    const words = slug.replace(/\.[a-z0-9]+$/i, "").split(/[-_+]/).filter(Boolean);
    if (!words.length) return "Saved item";
    return words
      .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
      .join(" ")
      .slice(0, 120);
  } catch {
    return "Saved item";
  }
}

async function scrape(url: string): Promise<Scraped> {
  const r = await fetch(url, { headers: { "User-Agent": UA, "Accept": "text/html" } });
  if (!r.ok) throw new Error(`page_fetch_failed_${r.status}`);
  const html = (await r.text()).slice(0, 600_000); // cap parse work

  const ld = fromJsonLd(html);

  let name = ld.name
    ?? metaContent(html, "og:title")
    ?? metaContent(html, "twitter:title");
  if (!name) {
    const t = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1];
    if (t) name = decodeEntities(t);
  }

  // Validate each candidate independently — a malformed value from a
  // preferred source (JSON-LD) must not shadow a valid og:image.
  const image = absolutize(ld.image ?? null, url)
    ?? absolutize(metaContent(html, "og:image:secure_url"), url)
    ?? absolutize(metaContent(html, "og:image"), url)
    ?? absolutize(metaContent(html, "twitter:image"), url);

  const price = ld.price
    ?? metaContent(html, "product:price:amount")
    ?? metaContent(html, "og:price:amount");

  const brand = ld.brand ?? metaContent(html, "og:site_name");

  return {
    name: (name ?? "Saved item").slice(0, 120),
    image,
    price: price ? String(price).slice(0, 40) : null,
    brand: brand ? String(brand).slice(0, 60) : null,
  };
}

// ---------- FAL polish (same pipeline as promote-product) ----------

async function dataUriFromUrl(url: string, referer?: string): Promise<string> {
  const headers: Record<string, string> = {
    "User-Agent": UA,
    "Accept": "image/avif,image/webp,image/*,*/*;q=0.8",
  };
  if (referer) {
    headers["Referer"] = referer;
    try { headers["Origin"] = new URL(referer).origin; } catch { /* ignore */ }
  }
  const r = await fetch(url, { headers });
  if (!r.ok) throw new Error("image_fetch_failed");
  const type = r.headers.get("content-type") || "image/jpeg";
  const bytes = new Uint8Array(await r.arrayBuffer());
  return `data:${type};base64,${encodeBase64(bytes)}`;
}

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

// Background: polish the raw image into a cut-out and swap it into the row.
async function polish(
  userClient: ReturnType<typeof createClient>,
  productId: string,
  userId: string,
  rawImage: string,
  imageData: string | undefined,
  sourceUrl: string,
  name: string,
  falKey: string,
): Promise<void> {
  try {
    // Prefer the base64 the extension captured in-page — the server usually
    // can't fetch bot-walled retailer CDNs. Fall back to a referer'd fetch.
    const nanoInput = imageData && imageData.startsWith("data:")
      ? imageData
      : await dataUriFromUrl(rawImage, sourceUrl);
    const nano = await falRun(
      "fal-ai/nano-banana/edit",
      { prompt: nanoPrompt(name), image_urls: [nanoInput] },
      falKey,
    );
    const nanoUrl = nano?.images?.[0]?.url;
    if (!nanoUrl) throw new Error("nano_no_image");

    const bria = await falRun(
      "fal-ai/bria/background/remove",
      { image_url: await dataUriFromUrl(nanoUrl) },
      falKey,
    );
    const briaImg = bria?.image;
    const cutoutUrl = Array.isArray(briaImg) ? briaImg[0]?.url : briaImg?.url;
    if (!cutoutUrl) throw new Error("bria_no_image");

    const pngResp = await fetch(cutoutUrl);
    if (!pngResp.ok) throw new Error("cutout_fetch_failed");
    const pngBytes = new Uint8Array(await pngResp.arrayBuffer());

    const path = `${userId}/share-${Date.now()}.png`;
    const { error: upErr } = await userClient.storage
      .from("products")
      .upload(path, pngBytes, { contentType: "image/png", upsert: false });
    if (upErr) throw new Error(`upload_failed:${upErr.message}`);
    const imageUrl = userClient.storage.from("products").getPublicUrl(path).data.publicUrl;

    await userClient
      .from("products")
      .update({ image_url: imageUrl, thumb_status: "ready" })
      .eq("id", productId);
    console.log("share-save: polished", productId);
  } catch (e) {
    // Graceful: the row keeps the raw retailer image and can be re-polished
    // in-app via "Add to Yafa". Clear the generating flag so the sparkle
    // overlay stops (it just shows the raw photo). Surface in logs.
    console.error("share-save polish failed", productId, String((e as Error)?.message ?? e));
    await userClient
      .from("products")
      .update({ thumb_status: "ready" })
      .eq("id", productId);
  }
}

// ---------- Handler ----------

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const falKey = Deno.env.get("FAL_API_KEY");
  if (!supabaseUrl || !anonKey || !falKey) return json(500, { error: "misconfigured" });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json(401, { error: "missing_auth" });

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) {
    console.error("share-save invalid_auth", authErr?.message ?? "no user");
    return json(401, { error: "invalid_auth" });
  }
  console.log("share-save: authed user", user.id);

  let urlIn: string;
  let provided: { name?: string; image?: string; imageData?: string; price?: string; brand?: string };
  try {
    const body = await req.json();
    urlIn = String(body?.url ?? "").trim();
    provided = {
      name: body?.name ? String(body.name) : undefined,
      image: body?.image ? String(body.image) : undefined,
      imageData: body?.imageData ? String(body.imageData) : undefined,
      price: body?.price ? String(body.price) : undefined,
      brand: body?.brand ? String(body.brand) : undefined,
    };
  } catch {
    return json(400, { error: "bad_request" });
  }
  if (!/^https?:\/\//i.test(urlIn)) return json(400, { error: "invalid_url" });

  // Prefer fields the extension scraped IN the page (Safari JS) — the server
  // can't fetch most retail pages (bot-walls). Only fall back to a server-side
  // scrape when the client didn't supply an image (e.g. a non-Safari share).
  let scraped: Scraped;
  if (provided.image) {
    scraped = {
      name: (provided.name ?? "Saved item").slice(0, 120),
      image: provided.image,
      price: provided.price ? provided.price.slice(0, 40) : null,
      brand: provided.brand ? provided.brand.slice(0, 60) : null,
    };
    console.log("share-save: using in-page fields", JSON.stringify(scraped));
  } else {
    console.log("share-save: server-scraping", urlIn);
    // Bot-walled shops (Farfetch 403s the page itself) used to make
    // the save HARD-FAIL here. Save a stub instead: name derived
    // from the URL slug, no image, flagged for the app's WebKit
    // backfill (the app renders the page like Safari — past the
    // wall — then fills in the real details and a snapshot image).
    try {
      scraped = await scrape(urlIn);
    } catch (e) {
      console.error("share-save scrape_failed, saving stub", String((e as Error)?.message ?? e));
      scraped = { name: nameFromSlug(urlIn), image: null, price: null, brand: null };
    }
    console.log("share-save: scraped", JSON.stringify(scraped));
    if (!scraped.name || scraped.name === "Saved item") {
      scraped.name = nameFromSlug(urlIn);
    }
  }

  // Insert the wishlist row immediately with the raw image (fast response).
  const { data: inserted, error: insErr } = await userClient
    .from("products")
    .insert({
      user_id: user.id,
      name: scraped.name,
      // Empty string, NOT null: the app's WardrobeItem decodes
      // image_url as a required String — a stub must stay decodable.
      image_url: scraped.image ?? "",
      category: "unknown",
      brand: scraped.brand,
      price: scraped.price,
      source_url: urlIn,
      status: "wishlist",
      // No image = the shop blocked server scraping; the app's
      // WebKit backfill picks these up on next launch.
      thumb_status: scraped.image ? "generating" : "needs_client_scrape",
      tags: [],
    })
    .select("id")
    .single();
  if (insErr) {
    console.error("share-save insert_failed", insErr.message);
    return json(500, { error: "insert_failed", detail: insErr.message });
  }
  console.log("share-save: inserted row", inserted.id);

  // Polish the thumbnail in the background — the response returns now.
  // Stub rows (no image) skip polish; the app's backfill supplies the
  // image later.
  if (scraped.image || provided.imageData) {
    const work = polish(userClient, inserted.id, user.id, scraped.image ?? "", provided.imageData, urlIn, scraped.name, falKey);
    if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) {
      EdgeRuntime.waitUntil(work);
    } else {
      // Fallback if waitUntil is unavailable: await inline (slower response).
      await work;
    }
  }

  return json(200, {
    product_id: inserted.id,
    name: scraped.name,
    image_url: scraped.image,
    status: "wishlist",
  });
});
