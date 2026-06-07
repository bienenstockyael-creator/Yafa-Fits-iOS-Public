# Deploying `fal-proxy` for 2.0.1

This Edge Function holds the real FAL + OpenAI API keys server-side
so the iOS app can drop the bundled `FALAPIKey` / `OpenAIAPIKey` it
shipped in 2.0.

## One-time setup

You'll need the `supabase` CLI logged into the Yafa project (you
already are if you've been running migrations from this machine).

### 1. Set the server-side secrets

```bash
cd /Users/yaelbienenstock/Documents/Developer/Yafa-Fits-iOS-Public

supabase secrets set \
  FAL_API_KEY=<your-current-FAL-key> \
  OPENAI_API_KEY=<your-current-OpenAI-key> \
  --project-ref dqvwutzoakfmnhbsefsw
```

The current values are in `Config/Secrets.xcconfig` (rotate AFTER
deploying — see step 4).

### 2. Deploy the function

```bash
supabase functions deploy fal-proxy \
  --project-ref dqvwutzoakfmnhbsefsw
```

The function lives at:
`https://dqvwutzoakfmnhbsefsw.supabase.co/functions/v1/fal-proxy`

### 3. Smoke-test the function

Quick health check that it's deployed and rejecting unauthenticated
calls properly:

```bash
curl -i -X POST \
  https://dqvwutzoakfmnhbsefsw.supabase.co/functions/v1/fal-proxy \
  -H "Content-Type: application/json" \
  -d '{"url":"https://queue.fal.run/fal-ai/sam2/image"}'
```

Expected: `HTTP 401` with `{"error":{"code":"missing_auth", ...}}`.
That confirms the function is live and the JWT gate is working.

### 4. ROTATE THE OLD KEYS

The 2.0 TestFlight build on testers' phones contains the OLD
`FALAPIKey` and `OpenAIAPIKey`. Anyone with that IPA can extract
them. Once the new 2.0.1 is live and confirmed working:

1. Go to https://fal.ai/dashboard/keys → revoke the OLD FAL key
2. Go to https://platform.openai.com/api-keys → revoke the OLD
   OpenAI key
3. Re-create both, copy the new values
4. Run `supabase secrets set FAL_API_KEY=<new> OPENAI_API_KEY=<new>`
   (no need to re-deploy — secrets are picked up live)

**Do NOT rotate before step 3 confirms 2.0.1 works** — otherwise
your 2.0 users (and your own dev builds) will start hitting auth
errors mid-generation.

## Smoke test from the iOS app

After deploying the function AND running a 2.0.1 build:

1. Open the app, sign in
2. Tap the Quick Add flow → upload a photo → trigger SAM2
   segmentation
3. If the mask appears as before, the proxy is working
4. If you see a 401 / "Sign in is required" error, the JWT didn't
   reach the proxy correctly — check the Supabase function logs
   (`supabase functions logs fal-proxy --project-ref dqvwutzoakfmnhbsefsw`)

## How the routing works

The iOS app's `AIProxyClient` (in `YaelFits/Services/AIProxyClient.swift`)
inspects every outgoing HTTP request:

- If the URL's host is on `proxiedHosts` (`queue.fal.run`,
  `fal.run`, `fal.media`, `v3.fal.media`, `api.openai.com`), the
  request is wrapped in a JSON envelope (`{ url, method, headers,
  body }`) and POSTed to `fal-proxy` with the user's Supabase
  JWT
- Otherwise, the request goes through `URLSession.shared` unchanged

The Edge Function:
1. Verifies the JWT (Supabase auth lookup)
2. Validates the target URL is on its own allow-list (same hosts)
3. Strips the caller's `Authorization` header
4. Injects the right server-side key (`Key {FAL_API_KEY}` for
   FAL, `Bearer {OPENAI_API_KEY}` for OpenAI)
5. Forwards the request and streams the response back

## Cost expectations

Edge Function invocations are free up to 500K/month on Supabase's
free tier. Each FAL inference generates ~3-6 Edge Function calls
(submit + poll + asset downloads). At 100 testers × 5 generations
per day, that's ~3K calls/day — well under the limit.

Bandwidth is the same FAL data going through Supabase's network
once. Asset downloads (image masks, generated outfits) are
streamed (no buffering) so memory is bounded.
