# Yafa Generation Worker

This worker polls `public.generation_jobs`, processes queued jobs server-side, and uploads the generated frame sequence to Supabase Storage so the iOS app can review the outfit without doing the heavy work on-device.

## What it does

1. Claims the next queued job.
2. Downloads the uploaded source image from the `generation-inputs` bucket.
3. Calls fal Bria background removal.
4. Calls Kling image-to-video.
5. Extracts a transparent WebP frame sequence with `ffmpeg`.
6. Uploads the frames to the public `generated-outfits` bucket.
7. Writes a review-ready `remote_outfit` payload back to `generation_jobs`.
8. Sends an APNs completion push when APNs credentials are configured.

## Required environment variables

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `FAL_API_KEY`
- `FFMPEG_BIN`
- `APNS_KEY_ID`
- `APNS_TEAM_ID`
- `APNS_PRIVATE_KEY`
- `APNS_TOPIC`
- `APNS_ENV`

`FFMPEG_BIN` should point to an installed `ffmpeg` binary in the worker environment.

## Deployment

This folder includes a `Dockerfile` and `.env.example`, so you can deploy it as a long-running worker on Railway, Render, Fly.io, or any container host.

Recommended rollout:

1. Apply `supabase/migrations/202604150940_server_generation_and_push.sql`.
2. Set the environment variables from `.env.example`.
3. Build and run the container from this directory.
4. Keep one worker replica running continuously.

## Notes

- This worker is designed to run continuously on a server process manager such as Railway, Render, Fly.io, or a container host.
- The iOS app already knows how to consume the `generation_jobs` contract added in `supabase/schema.sql`.
- The app now uploads APNs device tokens to `device_push_tokens`, and the worker will send completion pushes when the APNs variables above are configured.
