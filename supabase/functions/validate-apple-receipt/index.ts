// Server-side handler for paid-credit IAP purchases.
//
// iOS calls this after a successful `Product.purchase()` returns a
// `VerifiedTransaction` with a JWS string. The function:
//   1. Authenticates the caller via their Supabase JWT.
//   2. Decodes the StoreKit 2 JWS payload to extract the
//      transaction ID + product ID claimed by Apple.
//   3. Cross-checks the `product_id` from the request against the
//      `productId` Apple signed into the JWS (defends against a
//      client passing a CHEAP product ID alongside an EXPENSIVE
//      JWS, or vice-versa).
//   4. Maps the product ID to a credit count using a
//      server-controlled allowlist (clients can't smuggle in a
//      bogus credit count).
//   5. Calls the `grant_paid_credits` RPC under `service_role` to
//      append an audit row + bump `gen_credits_paid_balance` in
//      one transaction. The UNIQUE constraint on
//      `apple_transaction_id` is the idempotency guarantee —
//      duplicate calls return `was_already_credited: true`
//      without re-crediting.
//
// Request body (JSON):
//   { "jws": string, "product_id": string }
//
// Response (JSON):
//   { new_paid_balance: number, was_already_credited: boolean }
//
// SECURITY DEBT — MUST HARDEN BEFORE APP STORE RELEASE:
//   We currently DECODE the JWS payload without verifying its
//   signature against Apple's signing certificates. In sandbox
//   (TestFlight, .storekit testing) this is acceptable — no real
//   money. In production an attacker could craft a fake JWS with
//   any productId / transactionId and get arbitrary credits.
//
//   First attempt at chain verification used `@peculiar/x509` via
//   esm.sh; deployed cleanly but failed at runtime (function
//   returned 404, likely an ESM compatibility issue with Deno's
//   edge runtime). For production, the cleanest path is the App
//   Store Server API: iOS sends transactionId, this function
//   authenticates with an App Store Connect API key, calls
//   Apple's GET /inApps/v1/transactions/{transactionId}, and
//   trusts Apple's signed response. Setup requires an API key
//   from App Store Connect; runtime is just HTTPS + JWT signing.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

// Server-controlled bundle → credit mapping. NEVER trust the
// client's claim of how many credits a purchase is worth — it
// must originate here.
const BUNDLES: Record<string, { credits: number; price_cents: number }> = {
  "com.yafa.credits.single": { credits: 1, price_cents: 199 },
  "com.yafa.credits.starter": { credits: 3, price_cents: 499 },
  "com.yafa.credits.standard": { credits: 10, price_cents: 1399 },
  "com.yafa.credits.bestvalue": { credits: 30, price_cents: 3499 },
};

interface RequestPayload {
  jws?: string;
  product_id?: string;
}

interface JWSTransactionPayload {
  transactionId?: string;
  originalTransactionId?: string;
  productId?: string;
  bundleId?: string;
  environment?: "Sandbox" | "Production" | string;
  purchaseDate?: number;
  [key: string]: unknown;
}

serve(async (req) => {
  if (req.method !== "POST") {
    return jsonError(405, "method_not_allowed", "POST required");
  }

  // ── 1. Authenticate the caller ─────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return jsonError(401, "missing_auth", "Authorization header required");
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
    return jsonError(500, "misconfigured", "Server env vars missing");
  }

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return jsonError(401, "invalid_auth", "Invalid or expired token");
  }

  // ── 2. Parse + validate request body ──────────────────────
  let body: RequestPayload;
  try {
    body = (await req.json()) as RequestPayload;
  } catch {
    return jsonError(400, "bad_json", "Request body must be JSON");
  }

  const { jws, product_id } = body;
  if (!jws || typeof jws !== "string") {
    return jsonError(400, "missing_jws", "`jws` (string) is required");
  }
  if (!product_id || typeof product_id !== "string") {
    return jsonError(400, "missing_product_id", "`product_id` (string) is required");
  }

  const bundle = BUNDLES[product_id];
  if (!bundle) {
    return jsonError(400, "unknown_product", `No bundle config for ${product_id}`);
  }

  // ── 3. Decode JWS (TODO: verify signature) ─────────────────
  let payload: JWSTransactionPayload;
  try {
    payload = decodeJWSPayload(jws);
  } catch (err) {
    return jsonError(400, "bad_jws", `Couldn't decode JWS: ${err}`);
  }

  if (!payload.transactionId) {
    return jsonError(400, "missing_txn_id", "JWS payload has no transactionId");
  }
  if (payload.productId !== product_id) {
    return jsonError(
      400,
      "product_id_mismatch",
      `Request says ${product_id}, JWS says ${payload.productId}`,
    );
  }

  // ── 4. Grant via service-role RPC ─────────────────────────
  const serviceClient = createClient(supabaseUrl, serviceRoleKey);
  const { data, error: rpcError } = await serviceClient.rpc("grant_paid_credits", {
    p_user_id: user.id,
    p_apple_transaction_id: payload.transactionId,
    p_product_id: product_id,
    p_credits: bundle.credits,
    p_price_cents: bundle.price_cents,
    p_currency: "USD",
    p_receipt_payload: payload,
  });

  if (rpcError) {
    return jsonError(500, "rpc_failed", rpcError.message);
  }

  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

/// Decodes a JWS string's middle segment (the payload). Does NOT
/// verify the signature — that's the open security item flagged
/// at the top of the file.
function decodeJWSPayload(jws: string): JWSTransactionPayload {
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new Error(`JWS has ${parts.length} segments, expected 3`);
  }
  // JWS uses base64url (RFC 4648 §5): - and _ in place of + and /,
  // and trailing padding stripped. atob() is base64-standard so we
  // restore the substitutions + pad before decoding.
  const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(
    parts[1].length + ((4 - (parts[1].length % 4)) % 4),
    "=",
  );
  return JSON.parse(atob(padded));
}

function jsonError(status: number, code: string, message: string): Response {
  return new Response(
    JSON.stringify({ error: code, message }),
    {
      status,
      headers: { "Content-Type": "application/json" },
    },
  );
}
