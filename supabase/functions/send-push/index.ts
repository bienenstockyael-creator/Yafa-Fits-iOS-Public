// send-push — APNs sender for social notifications (likes / vibes / comments).
//
// Called by Postgres triggers (via pg_net) when someone likes, vibes, or
// comments on a fit. Looks up the recipient's device tokens, composes the
// alert from the actor's username, and posts to APNs.
//
// Secrets required (Edge Functions → send-push → Secrets):
//   APNS_KEY_ID   — the 10-char id of the APNs auth key
//   APNS_TEAM_ID  — Apple developer Team ID
//   APNS_P8       — full contents of the AuthKey_XXXX.p8 file
//   APNS_TOPIC    — bundle id (com.yafa.Yafa)
//   PUSH_SECRET   — shared secret the DB triggers send in x-push-secret
//
// Payload (JSON body from the trigger):
//   { kind: "like" | "vibe" | "comment",
//     recipient_id: uuid, actor_id: uuid,
//     outfit_id: string, body?: string }

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ---------- APNs JWT (ES256) ----------

let cachedJwt: { token: string; issuedAt: number } | null = null;

function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const raw = atob(body);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

async function apnsJwt(): Promise<string> {
  // APNs rejects tokens older than 60 min; reuse for 45.
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.issuedAt < 45 * 60) return cachedJwt.token;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(Deno.env.get("APNS_P8")!),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64url(JSON.stringify({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID") }));
  const claims = b64url(JSON.stringify({ iss: Deno.env.get("APNS_TEAM_ID"), iat: now }));
  const unsigned = `${header}.${claims}`;
  const sig = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      new TextEncoder().encode(unsigned),
    ),
  );
  const token = `${unsigned}.${b64url(sig)}`;
  cachedJwt = { token, issuedAt: now };
  return token;
}

// ---------- APNs delivery ----------

async function sendToToken(
  token: string,
  payload: Record<string, unknown>,
  collapseId: string,
  host = "https://api.push.apple.com",
): Promise<"ok" | "bad-token" | "retry-sandbox" | "failed"> {
  const res = await fetch(`${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJwt()}`,
      "apns-topic": Deno.env.get("APNS_TOPIC") ?? "com.yafa.Yafa",
      "apns-push-type": "alert",
      "apns-priority": "10",
      // Stable per-event identity: duplicate deliveries (e.g. stale
      // tokens for the same device after reinstalls) COLLAPSE into a
      // single visible banner instead of stacking repeats.
      "apns-collapse-id": collapseId,
    },
    body: JSON.stringify(payload),
  });
  if (res.ok) return "ok";
  const body = await res.text();
  // Tokens registered from dev builds live in the sandbox environment —
  // production APNs answers BadDeviceToken for them. Retry once there.
  if (body.includes("BadDeviceToken")) {
    return host.includes("api.push") ? "retry-sandbox" : "bad-token";
  }
  // Dead tokens (uninstalled app) should be pruned so we stop retrying.
  if (body.includes("Unregistered") || body.includes("ExpiredToken")) return "bad-token";
  console.error(`APNs ${res.status}: ${body}`);
  return "failed";
}

// ---------- request handler ----------

Deno.serve(async (req) => {
  if (req.headers.get("x-push-secret") !== Deno.env.get("PUSH_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }

  const { kind, recipient_id, actor_id, outfit_id, body } = await req.json();
  if (!kind || !recipient_id || !actor_id) {
    return new Response("bad request", { status: 400 });
  }
  // Never notify people about their own actions (also guarded in the
  // triggers — belt and suspenders).
  if (recipient_id === actor_id) return new Response("self", { status: 200 });

  // Actor's handle for the alert copy.
  const { data: actor } = await supabase
    .from("profiles")
    .select("username, display_name")
    .eq("id", actor_id)
    .single();
  const who = actor?.username ? `@${actor.username}` : (actor?.display_name ?? "Someone");

  let title: string;
  let alertBody: string;
  switch (kind) {
    case "like":
      title = `${who} liked your fit`;
      alertBody = "Open it to see which one.";
      break;
    case "vibe":
      title = `${who} sent your fit a vibe ✨`;
      alertBody = "Vibes bring you closer to a free 3D fit.";
      break;
    case "comment": {
      title = `${who} commented on your fit`;
      const preview = (body ?? "").slice(0, 120);
      alertBody = preview.length > 0 ? preview : "Tap to read it.";
      break;
    }
    case "follow":
      title = `${who} started following you 🙌`;
      alertBody = "Check out their fits.";
      break;
    default:
      return new Response("unknown kind", { status: 400 });
  }

  const { data: tokens } = await supabase
    .from("device_push_tokens")
    .select("token")
    .eq("user_id", recipient_id);
  if (!tokens || tokens.length === 0) return new Response("no tokens", { status: 200 });

  const payload = {
    aps: { alert: { title, body: alertBody }, sound: "default" },
    kind,
    outfit_id: outfit_id ?? null,
  };

  // 64-byte APNs limit; kind+actor+target uniquely names the event.
  const collapseId = `${kind}:${actor_id}:${outfit_id ?? recipient_id}`.slice(0, 64);

  let delivered = 0;
  const dead: string[] = [];
  for (const { token } of tokens) {
    let result = await sendToToken(token, payload, collapseId);
    if (result === "retry-sandbox") {
      result = await sendToToken(token, payload, collapseId, "https://api.sandbox.push.apple.com");
    }
    if (result === "ok") delivered++;
    if (result === "bad-token") dead.push(token);
  }
  if (dead.length > 0) {
    await supabase.from("device_push_tokens").delete().in("token", dead);
  }

  return new Response(JSON.stringify({ delivered, pruned: dead.length }), {
    headers: { "content-type": "application/json" },
  });
});
