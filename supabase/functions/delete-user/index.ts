// Account deletion (App Store Guideline 5.1.1(v)).
//
// Authenticates the caller via their Supabase JWT, then deletes the
// auth.users row under the service role. Every user-owned table
// references profiles(id) / auth.users(id) ON DELETE CASCADE, so this
// one call removes the profile, outfits, comments, likes, saves,
// follows, blocks, reports, device tokens, generation jobs, and credit
// records. Storage objects aren't covered by DB cascades, so we also
// best-effort wipe the user's uploaded inputs and avatars.
//
// Required env (auto-provided by the Supabase Edge Runtime):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy: supabase functions deploy delete-user

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.7";

serve(async (req) => {
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json(401, { error: "missing_auth" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json(500, { error: "misconfigured" });
  }

  // 1. Identify the caller from their JWT.
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return json(401, { error: "invalid_auth" });
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 2. Best-effort storage cleanup (private uploads + avatars). DB
  //    cascade handles everything else; failures here must not block
  //    the account deletion.
  await wipeFolder(admin, "generation-inputs", user.id);
  await wipeFolder(admin, "avatars", user.id);

  // 3. Delete the auth user — cascades remove all DB content.
  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) {
    return json(500, { error: "delete_failed", detail: deleteError.message });
  }

  return json(200, { ok: true });
});

/** Removes every object directly under `prefix/` in a bucket. */
async function wipeFolder(admin: ReturnType<typeof createClient>, bucket: string, prefix: string) {
  try {
    const { data: files } = await admin.storage.from(bucket).list(prefix, { limit: 1000 });
    if (files && files.length > 0) {
      await admin.storage
        .from(bucket)
        .remove(files.map((f: { name: string }) => `${prefix}/${f.name}`));
    }
  } catch (_) {
    // best effort — never block deletion on storage cleanup
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
