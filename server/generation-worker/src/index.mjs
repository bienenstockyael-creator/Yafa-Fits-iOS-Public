/**
 * Yafa Generation Worker
 *
 * Polls generation_jobs for queued rows and runs the full pipeline:
 *   FAL Bria background removal
 *   → green-screen composite (matches iOS ImageMaskingService.composeForKling exactly)
 *   → FAL Kling 2.5 Turbo 10-second orbit video
 *   → ffmpeg frame extraction (241 frames + duplicate of frame 0 = 242 total)
 *   → WebP conversion via Sharp (82% quality, matching iOS)
 *   → Upload to Supabase Storage generated-outfits bucket
 *   → APNs push notification
 */

import { createClient } from '@supabase/supabase-js';
import apn from '@parse/node-apn';
import sharp from 'sharp';
import { execFile } from 'child_process';
import { promisify } from 'util';
import fs from 'fs';
import path from 'path';
import os from 'os';

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// Constants — must match iOS exactly
// ---------------------------------------------------------------------------
const CANVAS_WIDTH  = 646;  // UploadConfig.compositionDimensions.width  (323*2)
const CANVAS_HEIGHT = 1100; // UploadConfig.compositionDimensions.height (550*2)
const FRAME_WIDTH   = 323;  // FrameConfig.dimensions.width
const FRAME_HEIGHT  = 550;  // FrameConfig.dimensions.height
const FRAMES_TOTAL  = 242;  // FrameConfig.framesPerOutfit
const FRAMES_EXTRACT = 241; // UploadConfig.extractedFrameCount (FRAMES_TOTAL - 1)
const WEBP_QUALITY  = 82;   // VideoFrameSequenceExporter.webPCompressionQuality

// ImageMaskingService constants
const COMP_WIDTH_RATIO    = 0.70;
const COMP_HEIGHT_RATIO   = 0.88;
const COMP_WIDTH_SAFETY   = 1.08;
const COMP_HEIGHT_SAFETY  = 1.08;
const GREEN_R = 23; const GREEN_G = 235; const GREEN_B = 79; // CIColor(0.09, 0.92, 0.31)

// VideoFrameSequenceExporter constants
const TARGET_SUBJECT_HEIGHT = FRAME_HEIGHT * 0.92; // 506px
const BOTTOM_MARGIN_RATIO   = 0.02;                // 11px
const BOUNDS_ALPHA_THRESHOLD = 40;

const FAL_API_KEY   = process.env.FAL_API_KEY;
const FFMPEG        = process.env.FFMPEG_BIN || 'ffmpeg';
const FFPROBE       = FFMPEG.replace('ffmpeg', 'ffprobe') === FFMPEG ? 'ffprobe' : FFMPEG.replace('ffmpeg', 'ffprobe');
const SUPABASE_URL  = process.env.SUPABASE_URL;
const STORAGE_BASE  = `${SUPABASE_URL}/storage/v1/object/public/generated-outfits/`;

const FAL_BRIA_URL  = 'https://queue.fal.run/fal-ai/bria/background/remove';
const FAL_KLING_URL = 'https://queue.fal.run/fal-ai/kling-video/v2.5-turbo/pro/image-to-video';
const DEFAULT_PROMPT = 'A smooth full 360 degrees circular camera orbit around the subject, moving anti clockwise (from right to left) at constant speed. The subject remains perfectly still and frozen in time.';

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------
const supabase = createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// Two providers: one for development, one for production.
// Tokens store their environment; we pick the right provider per token.
const apnTokenConfig = {
  key:    process.env.APNS_PRIVATE_KEY,
  keyId:  process.env.APNS_KEY_ID,
  teamId: process.env.APNS_TEAM_ID,
};
const apnProviderDev  = new apn.Provider({ token: apnTokenConfig, production: false });
const apnProviderProd = new apn.Provider({ token: apnTokenConfig, production: true  });
apnProviderDev.on('error',  (err) => console.error('APNs dev provider error:', err));
apnProviderProd.on('error', (err) => console.error('APNs prod provider error:', err));
const APNS_TOPIC = process.env.APNS_TOPIC || 'com.yafa.Yafa';

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
process.on('uncaughtException',  (err) => console.error('Uncaught exception:', err));
process.on('unhandledRejection', (reason) => console.error('Unhandled rejection:', reason));

// Graceful shutdown — requeue the active job so the next worker picks it up
let activeJobId = null;
let pollCount = 0;
async function shutdown(signal) {
  console.log(`${signal} received — shutting down gracefully`);
  if (activeJobId) {
    console.log(`Requeueing job ${activeJobId} for next worker`);
    await supabase
      .from('generation_jobs')
      .update({ status: 'queued', stage: 'upload', status_title: 'Queued', status_detail: 'Worker restarted — will resume shortly.' })
      .eq('id', activeJobId)
      .eq('status', 'processing');
  }
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

console.log('Yafa generation worker starting…');
console.log('  SUPABASE_URL:', SUPABASE_URL ? 'set' : 'MISSING');
console.log('  SUPABASE_SERVICE_ROLE_KEY:', process.env.SUPABASE_SERVICE_ROLE_KEY ? 'set' : 'MISSING');
console.log('  FAL_API_KEY:', FAL_API_KEY ? 'set' : 'MISSING');
console.log('  APNS_KEY_ID:', process.env.APNS_KEY_ID || 'MISSING');
console.log('  APNS_ENV:', process.env.APNS_ENV || 'MISSING');
console.log('  FFMPEG:', FFMPEG);

try {
  await resetStalledJobs();
  await pollLoop();
} catch (err) {
  console.error('Fatal error in main loop:', err);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------
async function pollLoop() {
  while (true) {
    try {
      // Re-run stall check every 10 minutes to catch jobs orphaned by prior crashes
      if (pollCount++ % 120 === 0 && pollCount > 1) {
        await resetStalledJobs();
      }

      const job = await claimNextJob();
      if (job) {
        activeJobId = job.id;
        await processJob(job);
        activeJobId = null;
      } else {
        await sleep(5_000);
      }
    } catch (err) {
      console.error('Poll error:', err.message);
      activeJobId = null;
      await sleep(5_000);
    }
  }
}

async function claimNextJob() {
  // Find oldest queued job
  const { data: rows } = await supabase
    .from('generation_jobs')
    .select('*')
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(1);

  if (!rows || rows.length === 0) return null;
  const candidate = rows[0];

  // Atomically claim it (handles concurrent workers)
  const { data: claimed } = await supabase
    .from('generation_jobs')
    .update({ status: 'processing', stage: 'removing_background' })
    .eq('id', candidate.id)
    .eq('status', 'queued')
    .select()
    .single();

  return claimed ?? null;
}

async function resetStalledJobs() {
  // Reset jobs stuck in processing for >30 minutes (e.g. worker crash)
  const cutoff = new Date(Date.now() - 30 * 60 * 1_000).toISOString();
  const { error } = await supabase
    .from('generation_jobs')
    .update({ status: 'queued', stage: 'upload' })
    .eq('status', 'processing')
    .lt('updated_at', cutoff);
  if (error) console.warn('resetStalledJobs:', error.message);
  else console.log('Stalled job reset complete.');
}

// ---------------------------------------------------------------------------
// Full pipeline
// ---------------------------------------------------------------------------
async function processJob(job) {
  console.log(`Job ${job.id}: outfit-${job.outfit_num} for user ${job.user_id}`);
  const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'yafa-'));

  try {
    // 1. Download source image
    await updateJob(job.id, { status_title: 'Downloading source', status_detail: 'Fetching your uploaded photo.' });
    const sourceBuffer = await downloadFromStorage('generation-inputs', job.source_image_path);

    // 2. FAL Bria background removal
    await updateJob(job.id, { stage: 'removing_background', status_title: 'Removing background', status_detail: 'Running FAL Bria background removal.' });
    console.log(`Job ${job.id}: source image ${sourceBuffer.length} bytes`);
    const transparentPNG = await falBriaRemoveBackground(sourceBuffer);
    console.log(`Job ${job.id}: bria result ${transparentPNG.length} bytes, first bytes: ${transparentPNG.slice(0,4).toString('hex')}`);

    // 3. Green-screen composite for Kling
    await updateJob(job.id, { status_title: 'Preparing canvas', status_detail: 'Compositing onto green-screen canvas.' });
    const greenScreenPNG = await composeForKling(transparentPNG);
    console.log(`Job ${job.id}: green screen ${greenScreenPNG.length} bytes`);

    // 4. FAL Kling video generation
    await updateJob(job.id, { stage: 'creating_interactive_fit', status_title: 'Submitting to Kling 2.5', status_detail: 'Sending green-screen to Kling for a 10-second orbit.' });
    const videoPath = path.join(tmpDir, 'orbit.mp4');
    await falKlingGenerateVideo(greenScreenPNG, job.prompt || DEFAULT_PROMPT, videoPath, async (title, detail) => {
      await updateJob(job.id, { stage: 'creating_interactive_fit', status_title: title, status_detail: detail });
    });

    // 5. Extract & process frames
    await updateJob(job.id, { stage: 'compressing', status_title: 'Extracting frames', status_detail: 'Building 242-frame interactive sequence.', progress: 0 });
    const outfitId = `outfit-${job.outfit_num}`;
    // Use job ID as a storage prefix so each attempt gets a unique URL,
    // preventing the app's DiskFrameCache from serving stale frames on retry.
    const storagePrefix = job.id;
    const webpPaths = await extractAndProcessFrames(videoPath, tmpDir, outfitId, async (progress) => {
      await updateJob(job.id, { progress, status_detail: `Processed ${Math.round(progress * FRAMES_TOTAL)} of ${FRAMES_TOTAL} frames.` });
    });

    // 6. Upload frames to Supabase Storage under {job-id}/outfit-N/
    await updateJob(job.id, { status_title: 'Uploading', status_detail: `Saving ${FRAMES_TOTAL} frames to cloud storage.` });
    await uploadFrames(webpPaths, outfitId, storagePrefix, async (progress) => {
      await updateJob(job.id, { progress: 0.7 + progress * 0.3 });
    });

    // 7. Build outfit record (camelCase to match Swift Codable)
    const today = new Date().toISOString().slice(0, 10);
    const remoteOutfit = {
      id: outfitId,
      name: `Outfit ${job.outfit_num}`,
      date: today,
      frameCount: FRAMES_TOTAL,
      folder: outfitId,
      prefix: `${outfitId}_`,
      frameExt: 'webp',
      remoteBaseURL: `${STORAGE_BASE}${storagePrefix}/`,
      isRotationReversed: false,
      tags: [],
      products: [],
    };

    // 8. Mark complete
    await supabase
      .from('generation_jobs')
      .update({
        status: 'complete',
        review_state: 'pending',
        stage: 'complete',
        status_title: 'Ready',
        status_detail: 'Your interactive fit is ready for review.',
        progress: 1.0,
        remote_outfit: remoteOutfit,
        completed_at: new Date().toISOString(),
      })
      .eq('id', job.id);

    console.log(`Job ${job.id}: complete`);

    // 9. Push notification
    await sendPushNotification(job.user_id);
  } catch (err) {
    console.error(`Job ${job.id} failed:`, err.message);
    await supabase
      .from('generation_jobs')
      .update({ status: 'failed', stage: 'failed', status_title: 'Generation failed', status_detail: err.message, error: err.message })
      .eq('id', job.id);
  } finally {
    await fs.promises.rm(tmpDir, { recursive: true, force: true }).catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// FAL Bria background removal
// ---------------------------------------------------------------------------
async function falBriaRemoveBackground(imageBuffer) {
  const dataURI = `data:image/jpeg;base64,${imageBuffer.toString('base64')}`;

  const submitRes = await falPost(FAL_BRIA_URL, { image_url: dataURI });
  const transparentBuffer = await falPollForResult(submitRes, async (result) => {
    // Handle different FAL response shapes
    const url = result?.image?.url ?? result?.images?.[0]?.url ?? result?.output?.image?.url;
    console.log('Bria result keys:', Object.keys(result || {}));
    if (!url) throw new Error(`No image URL in Bria result: ${JSON.stringify(result).slice(0, 200)}`);
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Bria image fetch failed: ${res.status} ${res.statusText}`);
    const buf = Buffer.from(await res.arrayBuffer());
    console.log(`Bria image fetched: ${buf.length} bytes, content-type: ${res.headers.get('content-type')}`);
    return buf;
  });

  return transparentBuffer;
}

// ---------------------------------------------------------------------------
// Green-screen compositing — mirrors iOS ImageMaskingService.composeForKling
// ---------------------------------------------------------------------------
async function composeForKling(transparentPNGBuffer) {
  const { data: pixels, info } = await sharp(transparentPNGBuffer)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const { width: srcW, height: srcH } = info;

  // Find non-transparent bounds (y-down, matches iOS nonTransparentBounds)
  let minX = srcW, minY = srcH, maxX = -1, maxY = -1;
  for (let y = 0; y < srcH; y++) {
    for (let x = 0; x < srcW; x++) {
      if (pixels[(y * srcW + x) * 4 + 3] > 1) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }

  if (maxX < minX) throw new Error('No subject found after background removal');

  const boundsW   = maxX - minX + 1;
  const boundsH   = maxY - minY + 1;
  const boundsMidX = (minX + maxX) / 2;
  const boundsMidY = (minY + maxY) / 2;

  // Scale — identical to iOS formula
  const scale = Math.min(
    (CANVAS_WIDTH  * COMP_WIDTH_RATIO)  / (boundsW * COMP_WIDTH_SAFETY),
    (CANVAS_HEIGHT * COMP_HEIGHT_RATIO) / (boundsH * COMP_HEIGHT_SAFETY),
  );

  // Center on canvas (y-down coordinate system matches CGImage used in iOS bounds detection)
  const left = Math.round(CANVAS_WIDTH  / 2 - boundsMidX * scale);
  const top  = Math.round(CANVAS_HEIGHT / 2 - boundsMidY * scale);

  const scaledW = Math.max(1, Math.round(srcW * scale));
  const scaledH = Math.max(1, Math.round(srcH * scale));

  const scaledSubject = await sharp(transparentPNGBuffer)
    .ensureAlpha()
    .resize(scaledW, scaledH, { fit: 'fill', kernel: 'lanczos3' })
    .toBuffer();

  // Sharp requires composite input ≤ base canvas dimensions.
  // Clip the scaled image to only the portion visible on the canvas
  // (iOS CIImage does this automatically via .cropped(to: canvasRect)).
  let compositeLeft = left;
  let compositeTop  = top;
  let extractLeft   = 0;
  let extractTop    = 0;
  let clipW         = scaledW;
  let clipH         = scaledH;

  if (compositeLeft < 0) { extractLeft = -compositeLeft; clipW += compositeLeft; compositeLeft = 0; }
  if (compositeTop  < 0) { extractTop  = -compositeTop;  clipH += compositeTop;  compositeTop  = 0; }
  if (compositeLeft + clipW > CANVAS_WIDTH)  clipW = CANVAS_WIDTH  - compositeLeft;
  if (compositeTop  + clipH > CANVAS_HEIGHT) clipH = CANVAS_HEIGHT - compositeTop;

  // Nothing visible — return plain green canvas
  if (clipW <= 0 || clipH <= 0) {
    return sharp({ create: { width: CANVAS_WIDTH, height: CANVAS_HEIGHT, channels: 3, background: { r: GREEN_R, g: GREEN_G, b: GREEN_B } } })
      .png().toBuffer();
  }

  // Extract only the visible slice if needed
  let visibleSubject = scaledSubject;
  if (extractLeft > 0 || extractTop > 0 || clipW < scaledW || clipH < scaledH) {
    visibleSubject = await sharp(scaledSubject)
      .extract({ left: extractLeft, top: extractTop, width: clipW, height: clipH })
      .toBuffer();
  }

  return sharp({
    create: { width: CANVAS_WIDTH, height: CANVAS_HEIGHT, channels: 3, background: { r: GREEN_R, g: GREEN_G, b: GREEN_B } },
  })
    .composite([{ input: visibleSubject, top: compositeTop, left: compositeLeft, blend: 'over' }])
    .png()
    .toBuffer();
}

// ---------------------------------------------------------------------------
// FAL Kling video generation
// ---------------------------------------------------------------------------
async function falKlingGenerateVideo(greenScreenPNGBuffer, prompt, outputPath, onUpdate) {
  const dataURI = `data:image/png;base64,${greenScreenPNGBuffer.toString('base64')}`;
  const submitRes = await falPost(FAL_KLING_URL, {
    prompt,
    image_url: dataURI,
    tail_image_url: dataURI,
    duration: '10',
  });

  const videoBuffer = await falPollForResult(submitRes, async (result) => {
    const url = result?.video?.url ?? result?.video?.[0]?.url;
    if (!url) throw new Error('No video URL in Kling result');
    await onUpdate('Downloading video', 'Pulling the generated video.');
    const res = await fetch(url);
    return Buffer.from(await res.arrayBuffer());
  }, async (status) => {
    if (status.status?.toLowerCase().includes('queue')) {
      const pos = status.queue_position;
      await onUpdate('Queued', pos ? `Queue position: ${pos}` : 'Waiting for a runner.');
    } else {
      await onUpdate('Generating 360° video', 'Kling is rendering the 10-second orbit.');
    }
  });

  await fs.promises.writeFile(outputPath, videoBuffer);
}

// ---------------------------------------------------------------------------
// Frame extraction — ffmpeg handles chromakey + scale + pad, Sharp converts to WebP
// (Avoids the Sharp-reads-JPEG issue: Sharp only touches small RGBA PNGs it wrote itself)
// ---------------------------------------------------------------------------
async function extractAndProcessFrames(videoPath, tmpDir, outfitId, onProgress) {
  let duration = 10;
  try {
    const { stdout } = await execFileAsync(FFPROBE, [
      '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', videoPath,
    ]);
    duration = parseFloat(stdout.trim()) || 10;
  } catch { /* use default 10s */ }

  const framesDir = path.join(tmpDir, 'frames');
  await fs.promises.mkdir(framesDir, { recursive: true });

  // Single ffmpeg pass: extract frames + chromakey + scale + pad → small RGBA PNGs (323x550)
  // Each PNG is ~700KB raw but PNG-compressed to ~50-100KB. 241 frames ≈ 15-25MB total.
  // Green screen color: 0x17EB4F = RGB(23,235,79)
  const vf = [
    `fps=${FRAMES_EXTRACT}/${duration}`,
    // Remove green background
    `chromakey=color=0x17EB4F:similarity=0.10:blend=0.00`,
    // Spill suppression: clamp the green channel to max(red, blue) in every pixel.
    // Kills the green tint on edges left behind by green-screen spill in the Kling video.
    `geq=r='r(X,Y)':g='min(g(X,Y),max(r(X,Y),b(X,Y)))':b='b(X,Y)':a='alpha(X,Y)'`,
    // Scale to fit within 323x550 preserving aspect ratio
    `scale=w=${FRAME_WIDTH}:h=${FRAME_HEIGHT}:force_original_aspect_ratio=decrease`,
    // Pad to exactly 323x550 with transparent background, centered
    `pad=w=${FRAME_WIDTH}:h=${FRAME_HEIGHT}:x=(ow-iw)/2:y=(oh-ih)/2:color=0x00000000`,
    `format=rgba`,
  ].join(',');

  await execFileAsync(FFMPEG, [
    '-i', videoPath,
    '-vf', vf,
    '-vsync', 'vfr',
    '-f', 'image2',
    path.join(framesDir, 'raw_%05d.png'),
  ]);

  const rawFiles = (await fs.promises.readdir(framesDir))
    .filter(f => f.startsWith('raw_') && f.endsWith('.png'))
    .sort();

  console.log(`Extracted ${rawFiles.length} RGBA frames at ${FRAME_WIDTH}x${FRAME_HEIGHT}`);
  if (rawFiles.length === 0) throw new Error('ffmpeg extracted no frames');

  await onProgress(0.05);

  // Detect subject bounds across sampled frames using Sharp on the RGBA PNGs.
  // Sharp CAN read these (proven: WebP conversion works). JPEG was the problem, not PNG.
  let unionMinX = Infinity, unionMinY = Infinity, unionMaxX = -Infinity, unionMaxY = -Infinity;
  const sampleStep = 8;
  for (let i = 0; i < rawFiles.length; i += sampleStep) {
    try {
      const pngPath = path.join(framesDir, rawFiles[i]);
      const { data } = await sharp(pngPath).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
      for (let y = 0; y < FRAME_HEIGHT; y++) {
        for (let x = 0; x < FRAME_WIDTH; x++) {
          const alpha = data[(y * FRAME_WIDTH + x) * 4 + 3];
          if (alpha > 40) {
            if (x < unionMinX) unionMinX = x;
            if (y < unionMinY) unionMinY = y;
            if (x > unionMaxX) unionMaxX = x;
            if (y > unionMaxY) unionMaxY = y;
          }
        }
      }
    } catch (e) { console.warn('bounds sample error frame', i, e.message); }
  }

  // Compute stable layout: scale so subject fills 92% of frame height, bottom-aligned
  const TARGET_SUBJECT_H = FRAME_HEIGHT * 0.92;  // 506px
  const BOTTOM_MARGIN    = FRAME_HEIGHT * 0.02;  // 11px
  let layoutScale = 1, cropLeft = 0, cropTop = 0;

  if (unionMaxX >= unionMinX) {
    const personH   = unionMaxY - unionMinY + 1;
    const personMidX = (unionMinX + unionMaxX) / 2;
    layoutScale = TARGET_SUBJECT_H / personH;

    cropLeft = personMidX * layoutScale - FRAME_WIDTH / 2;
    cropTop  = unionMaxY * layoutScale - (FRAME_HEIGHT - BOTTOM_MARGIN);
    console.log(`Subject ${personH}px tall → scale ${layoutScale.toFixed(3)}, crop (${Math.round(cropLeft)}, ${Math.round(cropTop)})`);
  } else {
    console.warn('Could not detect subject bounds — using default scale');
  }

  // Convert each PNG → WebP with stable layout applied
  const webpPaths = [];
  for (let i = 0; i < Math.min(rawFiles.length, FRAMES_EXTRACT); i++) {
    const pngPath = path.join(framesDir, rawFiles[i]);
    const webpName = `${outfitId}_${String(i).padStart(5, '0')}.webp`;
    const webpPath = path.join(framesDir, webpName);

    const scaledW = Math.max(FRAME_WIDTH,  Math.round(FRAME_WIDTH  * layoutScale));
    const scaledH = Math.max(FRAME_HEIGHT, Math.round(FRAME_HEIGHT * layoutScale));
    const left    = Math.max(0, Math.min(Math.round(cropLeft), scaledW - FRAME_WIDTH));
    const top     = Math.max(0, Math.min(Math.round(cropTop),  scaledH - FRAME_HEIGHT));

    let pipeline = sharp(pngPath).ensureAlpha();
    if (layoutScale > 1.05) {
      pipeline = pipeline
        .resize(scaledW, scaledH, { kernel: 'lanczos3' })
        .extract({ left, top, width: FRAME_WIDTH, height: FRAME_HEIGHT });
    }
    await pipeline.webp({ quality: WEBP_QUALITY }).toFile(webpPath);

    await fs.promises.unlink(pngPath).catch(() => {});
    webpPaths.push(webpPath);
    if (i % 20 === 0) await onProgress(0.05 + (i / FRAMES_EXTRACT) * 0.6);
  }

  // Frame 241 = duplicate of frame 0 for seamless loop (matches iOS)
  const loopFrame = path.join(framesDir, `${outfitId}_${String(FRAMES_TOTAL - 1).padStart(5, '0')}.webp`);
  await fs.promises.copyFile(webpPaths[0], loopFrame);
  webpPaths.push(loopFrame);

  return webpPaths;
}

// ---------------------------------------------------------------------------
// Upload frames to Supabase Storage
// ---------------------------------------------------------------------------
async function uploadFrames(webpPaths, outfitId, storagePrefix, onProgress) {
  for (let i = 0; i < webpPaths.length; i++) {
    const frameData = await fs.promises.readFile(webpPaths[i]);
    const remotePath = `${storagePrefix}/${outfitId}/${path.basename(webpPaths[i])}`;

    // Retry up to 4 times with backoff — Supabase occasionally returns Gateway Timeout
    let lastError;
    for (let attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) await sleep(1000 * attempt);
      const { error } = await supabase.storage
        .from('generated-outfits')
        .upload(remotePath, frameData, { contentType: 'image/webp', upsert: true });
      if (!error) { lastError = null; break; }
      lastError = error;
      console.warn(`Upload attempt ${attempt + 1} failed for frame ${i}: ${error.message}`);
    }
    if (lastError) throw new Error(`Upload failed for ${remotePath}: ${lastError.message}`);
    if (i % 20 === 0) await onProgress(i / webpPaths.length);
  }
  await onProgress(1);
}

// ---------------------------------------------------------------------------
// APNs push notification
// ---------------------------------------------------------------------------
async function sendPushNotification(userId) {
  const { data: tokens } = await supabase
    .from('device_push_tokens')
    .select('token,environment')
    .eq('user_id', userId)
    .eq('platform', 'ios');

  if (!tokens || tokens.length === 0) {
    console.log(`No device tokens for user ${userId}`);
    return;
  }

  for (const { token, environment } of tokens) {
    const note = new apn.Notification();
    note.expiry   = Math.floor(Date.now() / 1000) + 3600;
    note.badge    = 1;
    note.sound    = 'default';
    note.alert    = { title: 'Your interactive fit is ready ✨', body: 'Tap to review and add it to your archive.' };
    note.payload  = { route: 'upload' };
    note.topic    = APNS_TOPIC;

    const provider = environment === 'production' ? apnProviderProd : apnProviderDev;
    console.log(`Sending push via ${environment} APNs to ${token.slice(0,20)}...`);
    const result = await provider.send(note, token);
    if (result.failed.length > 0) {
      console.warn(`APNs failed:`, result.failed[0].response);
    } else {
      console.log(`Push sent successfully`);
    }
  }
}

// ---------------------------------------------------------------------------
// FAL helpers
// ---------------------------------------------------------------------------
async function falPost(url, body) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Authorization': `Key ${FAL_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`FAL submit failed ${res.status}: ${text}`);
  }
  return res.json();
}

async function falPollForResult(submitResponse, onComplete, onProgress, timeoutMs = 10 * 60 * 1000) {
  const deadline = Date.now() + timeoutMs;
  while (true) {
    if (Date.now() > deadline) throw new Error(`FAL job timed out after ${timeoutMs/60000} minutes`);
    await sleep(3_000);
    const statusRes = await fetch(submitResponse.status_url, {
      headers: { 'Authorization': `Key ${FAL_API_KEY}` },
      signal: AbortSignal.timeout(30_000),
    });
    const status = await statusRes.json();
    const s = (status.status || '').toLowerCase();

    if (s === 'completed') {
      const resultRes = await fetch(submitResponse.response_url, {
        headers: { 'Authorization': `Key ${FAL_API_KEY}` },
      });
      return onComplete(await resultRes.json());
    }
    if (s === 'failed' || s === 'error') {
      throw new Error(status.error?.message || 'FAL job failed');
    }
    if (onProgress) await onProgress(status);
  }
}

// ---------------------------------------------------------------------------
// Supabase helpers
// ---------------------------------------------------------------------------
async function downloadFromStorage(bucket, filePath) {
  const { data, error } = await supabase.storage.from(bucket).download(filePath);
  if (error) throw new Error(`Storage download failed: ${error.message}`);
  return Buffer.from(await data.arrayBuffer());
}

async function updateJob(jobId, fields) {
  await supabase.from('generation_jobs').update(fields).eq('id', jobId);
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
