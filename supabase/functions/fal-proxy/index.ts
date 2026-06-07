// Proxies FAL + OpenAI API calls so the iOS app doesn't have to
// ship those API keys inside its bundle. Caller authenticates with
// their Supabase JWT; the function verifies the JWT, injects the
// server-side `FAL_API_KEY` / `OPENAI_API_KEY` env var, and
// forwards the request to the original FAL/OpenAI URL.
//
// Request body shape (JSON):
//   {
//     "url": "https://queue.fal.run/fal-ai/sam2/image",   // required
//     "method": "POST" | "GET" | "PUT" | "DELETE",         // optional, default POST
//     "headers": { "Content-Type": "application/json" },   // optional
//     "body": <any>                                        // optional, forwarded as-is
//   }
//
// The response from FAL/OpenAI is returned verbatim — status,
// headers, body. Streamed so large asset downloads don't get
// buffered in memory.
//
// Security model:
//   - Caller MUST provide a valid Supabase JWT in `Authorization: Bearer`
//   - Target URL MUST match the allowed-hosts list (prevents this
//     function from being used as an open proxy)
//   - Server's FAL_API_KEY / OPENAI_API_KEY env vars never leave the
//     function runtime

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

// Hosts the proxy is allowed to forward to. Limiting this prevents
// a leaked JWT from being used to relay traffic anywhere.
const ALLOWED_HOSTS = new Set([
  "queue.fal.run",
  "fal.run",
  "fal.media",      // FAL's CDN for generated assets
  "v3.fal.media",   // Newer CDN domain
  "api.openai.com",
]);

// Headers we strip from the incoming request before forwarding —
// we don't want the caller's Authorization (which is their Supabase
// JWT) to leak to FAL/OpenAI; we inject the server's key instead.
const STRIPPED_HEADERS = new Set([
  "authorization",
  "host",
  "content-length", // recomputed by fetch
]);

interface ProxyPayload {
  url?: string;
  method?: string;
  headers?: Record<string, string>;
  body?: unknown;
}

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const falApiKey = Deno.env.get("FAL_API_KEY") ?? "";
const openaiApiKey = Deno.env.get("OPENAI_API_KEY") ?? "";

serve(async (req) => {
  // CORS preflight: standard handshake so the iOS client (which
  // sets non-trivial headers) doesn't get blocked.
  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: corsHeaders(),
    });
  }

  // Validate JWT — only authenticated Supabase users can hit this.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonError(401, "missing_auth", "Authorization header required");
  }

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return jsonError(401, "invalid_jwt", "Authentication failed");
  }

  // Parse the proxy payload.
  let payload: ProxyPayload;
  try {
    payload = await req.json();
  } catch {
    return jsonError(400, "invalid_body", "Request body must be JSON");
  }

  if (!payload.url) {
    return jsonError(400, "missing_url", "Body must include `url`");
  }

  let targetURL: URL;
  try {
    targetURL = new URL(payload.url);
  } catch {
    return jsonError(400, "invalid_url", "Body `url` is not a valid URL");
  }

  if (!ALLOWED_HOSTS.has(targetURL.hostname)) {
    return jsonError(
      403,
      "host_not_allowed",
      `Host ${targetURL.hostname} is not on the allow-list`,
    );
  }

  // Pick the right API key for the target host. OpenAI's API uses
  // `Authorization: Bearer`; FAL uses `Authorization: Key`.
  const isOpenAI = targetURL.hostname === "api.openai.com";
  const apiKey = isOpenAI ? openaiApiKey : falApiKey;
  const authValue = isOpenAI ? `Bearer ${apiKey}` : `Key ${apiKey}`;

  if (!apiKey) {
    return jsonError(
      500,
      "missing_server_key",
      `Server is missing the ${isOpenAI ? "OPENAI" : "FAL"}_API_KEY env var`,
    );
  }

  // Forward the request. Strip headers we don't want leaking
  // upstream; inject the real API key as Authorization.
  const forwardHeaders = new Headers();
  if (payload.headers) {
    for (const [key, value] of Object.entries(payload.headers)) {
      if (!STRIPPED_HEADERS.has(key.toLowerCase())) {
        forwardHeaders.set(key, value);
      }
    }
  }
  forwardHeaders.set("Authorization", authValue);

  const method = (payload.method ?? "POST").toUpperCase();
  const init: RequestInit = { method, headers: forwardHeaders };
  if (payload.body !== undefined && method !== "GET" && method !== "HEAD") {
    // Body can be a JSON value (object/array/string/number) — re-encode.
    // If the caller wanted to send a string, they'll have set Content-Type
    // to text/plain and passed a string; JSON.stringify handles both.
    if (typeof payload.body === "string") {
      init.body = payload.body;
    } else {
      init.body = JSON.stringify(payload.body);
      if (!forwardHeaders.has("Content-Type")) {
        forwardHeaders.set("Content-Type", "application/json");
      }
    }
  }

  let upstream: Response;
  try {
    upstream = await fetch(targetURL.toString(), init);
  } catch (err) {
    return jsonError(
      502,
      "upstream_unreachable",
      `Failed to reach ${targetURL.hostname}: ${err}`,
    );
  }

  // Pass through the upstream response. Strip hop-by-hop headers
  // and any auth FAL might echo back (defensive — it shouldn't,
  // but a misbehaving upstream could).
  const responseHeaders = new Headers();
  upstream.headers.forEach((value, key) => {
    const lower = key.toLowerCase();
    if (lower === "authorization") return;
    if (lower === "set-cookie") return; // we don't proxy cookies
    if (lower === "transfer-encoding") return; // recomputed by Deno
    responseHeaders.set(key, value);
  });
  // CORS so the iOS client can read the response.
  for (const [k, v] of Object.entries(corsHeaders())) {
    responseHeaders.set(k, v);
  }

  return new Response(upstream.body, {
    status: upstream.status,
    headers: responseHeaders,
  });
});

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
  };
}

function jsonError(status: number, code: string, message: string): Response {
  return new Response(
    JSON.stringify({ error: { code, message } }),
    {
      status,
      headers: { "Content-Type": "application/json", ...corsHeaders() },
    },
  );
}
