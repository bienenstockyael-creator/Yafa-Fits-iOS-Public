// Server-side handler for paid-credit IAP purchases.
//
// Production-grade verification: doesn't trust the iOS-submitted
// JWS payload at all. Instead, extracts the transactionId from
// the submitted JWS, then re-fetches that transaction directly
// from Apple's App Store Server API. Apple's response is
// authoritative — TLS to api.storekit(.sandbox).itunes.apple.com
// is our trust anchor.
//
// Flow:
//   1. Authenticate the caller via their Supabase JWT.
//   2. Decode the StoreKit 2 JWS body to extract transactionId
//      (we don't trust anything else in the payload; the cross-
//      check below catches forged claims).
//   3. Sign a JWT with the team's App Store Server API key
//      (ES256, .p8 private key from APPLE_IAP_PRIVATE_KEY).
//   4. Call Apple's GET /inApps/v1/transactions/{transactionId}
//      endpoint. Try production first; on 404, fall back to
//      sandbox. Apple's signed response is the source of
//      truth for productId / quantity / purchaseDate.
//   5. Cross-check the verified productId from Apple's response
//      against the product_id in the request — defends against
//      a client passing a CHEAP product_id alongside an
//      EXPENSIVE transactionId.
//   6. Map productId → credits via a server-controlled
//      allowlist.
//   7. Call grant_paid_credits RPC under service_role. The
//      UNIQUE constraint on apple_transaction_id is the
//      idempotency guarantee.
//
// Required env (set via supabase secrets / dashboard):
//   APPLE_IAP_KEY_ID         — 10-char Key ID
//   APPLE_IAP_ISSUER_ID      — UUID Issuer ID (team-level)
//   APPLE_IAP_PRIVATE_KEY    — PEM .p8 file contents
//   APPLE_IAP_BUNDLE_ID      — e.g. com.yafa.Yafa
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//     (auto-provided by Supabase Edge Runtime)

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

// Server-controlled bundle → credit mapping. Source of truth
// for how many credits each App Store product grants. NEVER
// trust client claims — the client can lie about anything.
const BUNDLES: Record<string, { credits: number; price_cents: number }> = {
  "com.yafa.credits.single": { credits: 1, price_cents: 199 },
  "com.yafa.credits.starter": { credits: 3, price_cents: 499 },
  // Standard lands at $12.99 (App Store price tiers don't
  // include $13.99 — Apple jumps from $12.99 to $14.99).
  "com.yafa.credits.standard": { credits: 10, price_cents: 1299 },
  "com.yafa.credits.bestvalue": { credits: 30, price_cents: 3499 },
};

const PROD_API = "https://api.storekit.itunes.apple.com/inApps/v1/transactions";
const SANDBOX_API = "https://api.storekit-sandbox.itunes.apple.com/inApps/v1/transactions";

interface RequestPayload {
  jws?: string;
  product_id?: string;
}

interface AppleTransactionInfo {
  transactionId?: string;
  originalTransactionId?: string;
  productId?: string;
  purchaseDate?: number;
  quantity?: number;
  environment?: string;
  bundleId?: string;
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
  const appleKeyId = Deno.env.get("APPLE_IAP_KEY_ID");
  const appleIssuerId = Deno.env.get("APPLE_IAP_ISSUER_ID");
  const applePrivateKey = Deno.env.get("APPLE_IAP_PRIVATE_KEY");
  const appleBundleId = Deno.env.get("APPLE_IAP_BUNDLE_ID");

  if (
    !supabaseUrl || !supabaseAnonKey || !serviceRoleKey ||
    !appleKeyId || !appleIssuerId || !applePrivateKey || !appleBundleId
  ) {
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

  // ── 3. Extract transactionId from the iOS-submitted JWS ───
  //    We don't TRUST the JWS contents — we just need the txn
  //    ID so we know which transaction to look up via Apple's
  //    API. The Apple-side fetch returns the authoritative
  //    record.
  let clientTransactionId: string;
  try {
    const payload = decodeJWSPayload(jws);
    if (!payload.transactionId) {
      return jsonError(400, "missing_txn_id", "JWS payload has no transactionId");
    }
    clientTransactionId = payload.transactionId;
  } catch (err) {
    return jsonError(400, "bad_jws", `Couldn't decode JWS: ${err}`);
  }

  // ── 4. Sign a JWT for Apple App Store Server API auth ─────
  let apiToken: string;
  try {
    apiToken = await signAppleAPIToken({
      keyId: appleKeyId,
      issuerId: appleIssuerId,
      bundleId: appleBundleId,
      privateKeyPEM: applePrivateKey,
    });
  } catch (err) {
    return jsonError(500, "jwt_sign_failed", `Couldn't sign Apple JWT: ${err}`);
  }

  // ── 5. Fetch authoritative transaction info from Apple ────
  //    Try production first; on 404 fall back to sandbox. Per
  //    Apple's guidance, the same transactionId can resolve in
  //    only one environment, and you should always try prod
  //    first so live transactions don't get routed to sandbox.
  let verifiedTxn: AppleTransactionInfo;
  let verifiedEnv: "Production" | "Sandbox";
  try {
    const result = await fetchTransactionFromApple({
      transactionId: clientTransactionId,
      apiToken,
    });
    verifiedTxn = result.transaction;
    verifiedEnv = result.environment;
  } catch (err) {
    return jsonError(502, "apple_api_failed", String(err));
  }

  // ── 6. Cross-check Apple's verified data ──────────────────
  if (verifiedTxn.productId !== product_id) {
    return jsonError(
      400,
      "product_id_mismatch",
      `Request says ${product_id}, Apple says ${verifiedTxn.productId}`,
    );
  }
  if (verifiedTxn.bundleId !== appleBundleId) {
    return jsonError(
      400,
      "bundle_id_mismatch",
      `Apple txn is for bundle ${verifiedTxn.bundleId}, not ${appleBundleId}`,
    );
  }
  if (!verifiedTxn.transactionId) {
    return jsonError(500, "apple_no_txn_id", "Apple response missing transactionId");
  }

  // ── 7. Grant via service-role RPC ─────────────────────────
  const serviceClient = createClient(supabaseUrl, serviceRoleKey);
  const { data, error: rpcError } = await serviceClient.rpc("grant_paid_credits", {
    p_user_id: user.id,
    p_apple_transaction_id: verifiedTxn.transactionId,
    p_product_id: product_id,
    p_credits: bundle.credits,
    p_price_cents: bundle.price_cents,
    p_currency: "USD",
    p_receipt_payload: { ...verifiedTxn, environment: verifiedEnv },
  });

  if (rpcError) {
    return jsonError(500, "rpc_failed", rpcError.message);
  }

  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

// ============================================================
// JWT signing for App Store Server API
// ============================================================

interface SignTokenArgs {
  keyId: string;
  issuerId: string;
  bundleId: string;
  privateKeyPEM: string;
}

/// Cached imported CryptoKey. Importing the PEM is the
/// expensive part — every cold start does it once, then warm
/// invocations re-use the imported key.
let cachedSigningKey: CryptoKey | null = null;
let cachedSigningKeyPEM: string | null = null;

async function signAppleAPIToken(args: SignTokenArgs): Promise<string> {
  // Reuse the imported key when the PEM hasn't changed (it
  // shouldn't within a function instance — secrets are read at
  // cold start).
  if (cachedSigningKey === null || cachedSigningKeyPEM !== args.privateKeyPEM) {
    cachedSigningKey = await importP8PrivateKey(args.privateKeyPEM);
    cachedSigningKeyPEM = args.privateKeyPEM;
  }

  const now = Math.floor(Date.now() / 1000);
  const header = {
    alg: "ES256",
    kid: args.keyId,
    typ: "JWT",
  };
  const payload = {
    iss: args.issuerId,
    iat: now,
    // 20-minute max per Apple's docs. We use 10 to be safe.
    exp: now + 600,
    aud: "appstoreconnect-v1",
    bid: args.bundleId,
  };

  const headerB64 = base64urlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = base64urlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = `${headerB64}.${payloadB64}`;

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cachedSigningKey,
    new TextEncoder().encode(signingInput),
  );
  // WebCrypto returns raw r||s for ECDSA (64 bytes for P-256),
  // which is exactly what JWT needs. No DER unwrapping required.
  const signatureB64 = base64urlEncode(new Uint8Array(signature));

  return `${signingInput}.${signatureB64}`;
}

/// Parses a PKCS#8 PEM-encoded ES256 (P-256) private key and
/// imports it as a non-extractable CryptoKey usable for signing.
async function importP8PrivateKey(pem: string): Promise<CryptoKey> {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

// ============================================================
// Apple App Store Server API
// ============================================================

interface FetchTransactionArgs {
  transactionId: string;
  apiToken: string;
}

interface FetchTransactionResult {
  transaction: AppleTransactionInfo;
  environment: "Production" | "Sandbox";
}

/// Tries the production endpoint first, falls back to sandbox
/// on 404. Matches Apple's recommended pattern for handling
/// transactions from either environment with a single code path.
async function fetchTransactionFromApple(
  args: FetchTransactionArgs,
): Promise<FetchTransactionResult> {
  // Production
  const prodResult = await tryFetch(PROD_API, args);
  if (prodResult) return { transaction: prodResult, environment: "Production" };

  // Sandbox fallback
  const sandboxResult = await tryFetch(SANDBOX_API, args);
  if (sandboxResult) return { transaction: sandboxResult, environment: "Sandbox" };

  throw new Error(`Transaction ${args.transactionId} not found in production or sandbox`);
}

async function tryFetch(
  baseURL: string,
  args: FetchTransactionArgs,
): Promise<AppleTransactionInfo | null> {
  const url = `${baseURL}/${encodeURIComponent(args.transactionId)}`;
  const res = await fetch(url, {
    headers: {
      Authorization: `Bearer ${args.apiToken}`,
      Accept: "application/json",
    },
  });
  if (res.status === 404) return null;
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Apple API ${res.status}: ${body}`);
  }
  const json = await res.json() as { signedTransactionInfo?: string };
  if (!json.signedTransactionInfo) {
    throw new Error("Apple response missing signedTransactionInfo");
  }
  // Apple's response is itself a JWS. We trust the TLS
  // connection (api.storekit.itunes.apple.com is Apple's
  // verified hostname) and just decode the payload. Adding
  // chain verification here would be defense-in-depth but
  // doesn't increase the trust ceiling beyond TLS.
  return decodeJWSPayload(json.signedTransactionInfo);
}

// ============================================================
// JWS payload decode (used for both iOS-submitted JWS and
// Apple's API response JWS)
// ============================================================

function decodeJWSPayload(jws: string): AppleTransactionInfo {
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new Error(`JWS has ${parts.length} segments, expected 3`);
  }
  const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(
    parts[1].length + ((4 - (parts[1].length % 4)) % 4),
    "=",
  );
  return JSON.parse(atob(padded));
}

// ============================================================
// Utilities
// ============================================================

function base64urlEncode(bytes: Uint8Array): string {
  let str = "";
  for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
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
