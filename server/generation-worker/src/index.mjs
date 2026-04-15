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

const apnProvider = new apn.Provider({
  token: {
    key:    process.env.APNS_PRIVATE_KEY,
    keyId:  process.env.APNS_KEY_ID,
    teamId: process.env.APNS_TEAM_ID,
  },
  production: process.env.APNS_ENV === 'production',
});
const APNS_TOPIC = process.env.APNS_TOPIC || 'com.yafa.Yafa';

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------
console.log('Yafa generation worker starting…');
await resetStalledJobs();
await pollLoop();

// ---------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------
async function pollLoop() {
  while (true) {
    try {
      const job = await claimNextJob();
      if (job) {
        await processJob(job);
      } else {
        await sleep(5_000);
      }
    } catch (err) {
      console.error('Poll error:', err.message);
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
    const transparentPNG = await falBriaRemoveBackground(sourceBuffer);

    // 3. Green-screen composite for Kling
    await updateJob(job.id, { status_title: 'Preparing canvas', status_detail: 'Compositing onto green-screen canvas.' });
    const greenScreenPNG = await composeForKling(transparentPNG);

    // 4. FAL Kling video generation
    await updateJob(job.id, { stage: 'creating_interactive_fit', status_title: 'Submitting to Kling 2.5', status_detail: 'Sending green-screen to Kling for a 10-second orbit.' });
    const videoPath = path.join(tmpDir, 'orbit.mp4');
    await falKlingGenerateVideo(greenScreenPNG, job.prompt || DEFAULT_PROMPT, videoPath, async (title, detail) => {
      await updateJob(job.id, { stage: 'creating_interactive_fit', status_title: title, status_detail: detail });
    });

    // 5. Extract & process frames
    await updateJob(job.id, { stage: 'compressing', status_title: 'Extracting frames', status_detail: 'Building 242-frame interactive sequence.', progress: 0 });
    const outfitId = `outfit-${job.outfit_num}`;
    const webpPaths = await extractAndProcessFrames(videoPath, tmpDir, outfitId, async (progress) => {
      await updateJob(job.id, { progress, status_detail: `Processed ${Math.round(progress * FRAMES_TOTAL)} of ${FRAMES_TOTAL} frames.` });
    });

    // 6. Upload frames to Supabase Storage
    await updateJob(job.id, { status_title: 'Uploading', status_detail: `Saving ${FRAMES_TOTAL} frames to cloud storage.` });
    await uploadFrames(webpPaths, outfitId, async (progress) => {
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
      remoteBaseURL: STORAGE_BASE,
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
    const url = result?.image?.url;
    if (!url) throw new Error('No image URL in Bria result');
    const res = await fetch(url);
    return Buffer.from(await res.arrayBuffer());
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

  return sharp({
    create: { width: CANVAS_WIDTH, height: CANVAS_HEIGHT, channels: 3, background: { r: GREEN_R, g: GREEN_G, b: GREEN_B } },
  })
    .composite([{ input: scaledSubject, top, left, blend: 'over' }])
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
// Frame extraction — mirrors VideoFrameSequenceExporter
// ---------------------------------------------------------------------------
async function extractAndProcessFrames(videoPath, tmpDir, outfitId, onProgress) {
  // Get actual video duration for accurate frame timing
  let duration = 10;
  try {
    const { stdout } = await execFileAsync(FFPROBE, [
      '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', videoPath,
    ]);
    duration = parseFloat(stdout.trim()) || 10;
  } catch { /* use default 10s */ }

  const framesDir = path.join(tmpDir, 'frames');
  await fs.promises.mkdir(framesDir, { recursive: true });

  // Extract FRAMES_EXTRACT evenly-spaced frames in one ffmpeg pass
  const fpsNum = FRAMES_EXTRACT;
  const fpsDen = duration;
  await execFileAsync(FFMPEG, [
    '-i', videoPath,
    '-vf', `fps=${fpsNum}/${fpsDen}`,
    '-vsync', 'vfr',
    '-f', 'image2',
    path.join(framesDir, 'raw_%05d.png'),
  ]);

  const rawFiles = (await fs.promises.readdir(framesDir))
    .filter(f => f.startsWith('raw_') && f.endsWith('.png'))
    .sort();

  if (rawFiles.length === 0) throw new Error('ffmpeg extracted no frames');

  // Compute stable layout from union of all frame bounds
  // (mirrors VideoFrameSequenceExporter.buildLayout)
  await onProgress(0.05);
  const layout = await buildStableLayout(framesDir, rawFiles);

  // Render each frame to WebP
  const webpPaths = [];
  for (let i = 0; i < Math.min(rawFiles.length, FRAMES_EXTRACT); i++) {
    const framePNG = path.join(framesDir, rawFiles[i]);
    const webpName = `${outfitId}_${String(i).padStart(5, '0')}.webp`;
    const webpPath = path.join(framesDir, webpName);
    await renderFrame(framePNG, layout, webpPath);
    webpPaths.push(webpPath);
    if (i % 10 === 0) await onProgress(0.05 + (i / FRAMES_EXTRACT) * 0.6);
  }

  // Frame 241 = duplicate of frame 0 for seamless loop (matches iOS)
  const loopFrame = path.join(framesDir, `${outfitId}_${String(FRAMES_TOTAL - 1).padStart(5, '0')}.webp`);
  await fs.promises.copyFile(webpPaths[0], loopFrame);
  webpPaths.push(loopFrame);

  return webpPaths;
}

async function buildStableLayout(framesDir, rawFiles) {
  // Union of non-transparent bounds across all frames (after chroma key)
  let unionMinX = Infinity, unionMinY = Infinity, unionMaxX = -Infinity, unionMaxY = -Infinity;
  let sourceW = 0, sourceH = 0;

  // Sample every 8th frame for speed (sufficient for union bounds)
  const sampleIndices = rawFiles.reduce((acc, _, i) => { if (i % 8 === 0) acc.push(i); return acc; }, []);
  // Always include first and last
  if (!sampleIndices.includes(rawFiles.length - 1)) sampleIndices.push(rawFiles.length - 1);

  for (const idx of sampleIndices) {
    const framePNG = path.join(framesDir, rawFiles[idx]);
    const { data: pixels, info } = await sharp(framePNG).raw().toBuffer({ resolveWithObject: true });
    sourceW = info.width;
    sourceH = info.height;
    const channels = info.channels; // 3 for RGB from ffmpeg

    const bounds = findChromaKeyedBounds(pixels, sourceW, sourceH, channels);
    if (bounds) {
      unionMinX = Math.min(unionMinX, bounds.minX);
      unionMinY = Math.min(unionMinY, bounds.minY);
      unionMaxX = Math.max(unionMaxX, bounds.maxX);
      unionMaxY = Math.max(unionMaxY, bounds.maxY);
    }
  }

  if (unionMaxX < unionMinX) throw new Error('Could not detect subject bounds in any frame');

  const boundsH = unionMaxY - unionMinY + 1;
  const scale   = TARGET_SUBJECT_HEIGHT / Math.max(boundsH, 1);

  // X: center subject horizontally (same in y-down)
  const xOffset = FRAME_WIDTH  / 2 - ((unionMinX + unionMaxX) / 2) * scale;

  // Y: bottom-align with small margin
  // In y-down: want feet (maxY) at frameHeight - bottomMargin
  const bottomMargin = FRAME_HEIGHT * BOTTOM_MARGIN_RATIO; // 11px
  const yOffset = (FRAME_HEIGHT - bottomMargin) - unionMaxY * scale;

  return { sourceW, sourceH, scale, xOffset, yOffset };
}

function findChromaKeyedBounds(pixels, width, height, channels) {
  let minX = width, minY = height, maxX = -1, maxY = -1;
  const stride = channels;

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const offset = (y * width + x) * stride;
      const r = pixels[offset] / 255;
      const g = pixels[offset + 1] / 255;
      const b = pixels[offset + 2] / 255;
      const alpha = chromaKeyAlpha(r, g, b);
      if (alpha * 255 > BOUNDS_ALPHA_THRESHOLD) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }
  return maxX >= minX ? { minX, minY, maxX, maxY } : null;
}

async function renderFrame(framePNG, layout, outputWebP) {
  const { data: rawPixels, info } = await sharp(framePNG).raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;

  // Apply chroma key: output RGBA
  const rgba = Buffer.alloc(width * height * 4);
  for (let i = 0; i < width * height; i++) {
    const src = i * channels;
    const r = rawPixels[src] / 255;
    const g = rawPixels[src + 1] / 255;
    const b = rawPixels[src + 2] / 255;
    const alpha = chromaKeyAlpha(r, g, b);

    const dst = i * 4;
    rgba[dst]     = rawPixels[src];
    // Reduce green fringing on semi-transparent edges (matches iOS color cube)
    rgba[dst + 1] = alpha < 1 ? Math.min(rawPixels[src + 1], Math.round(Math.max(rawPixels[src], rawPixels[src + 2]) * 1.08)) : rawPixels[src + 1];
    rgba[dst + 2] = rawPixels[src + 2];
    rgba[dst + 3] = Math.round(alpha * 255);
  }

  const keyedImg = sharp(rgba, { raw: { width, height, channels: 4 } });

  // Scale and position onto output canvas (323x550, transparent background)
  const scaledW = Math.max(1, Math.round(width  * layout.scale));
  const scaledH = Math.max(1, Math.round(height * layout.scale));

  const scaledBuf = await keyedImg
    .resize(scaledW, scaledH, { fit: 'fill', kernel: 'lanczos3' })
    .toBuffer();

  const left = Math.round(layout.xOffset);
  const top  = Math.round(layout.yOffset);

  await sharp({
    create: { width: FRAME_WIDTH, height: FRAME_HEIGHT, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
  })
    .composite([{ input: scaledBuf, top, left, blend: 'over' }])
    .webp({ quality: WEBP_QUALITY })
    .toFile(outputWebP);
}

// Mirrors iOS VideoFrameSequenceExporter.smoothstep + chroma key LUT
function smoothstep(edge0, edge1, value) {
  if (edge0 === edge1) return value < edge0 ? 0 : 1;
  const t = Math.min(Math.max((value - edge0) / (edge1 - edge0), 0), 1);
  return t * t * (3 - 2 * t);
}

function chromaKeyAlpha(r, g, b) {
  const maxRB      = Math.max(r, b);
  const greenBias  = g - maxRB;
  const saturation = Math.max(r, g, b) - Math.min(r, g, b);
  const keyStrength = smoothstep(0.02, 0.24, greenBias) * smoothstep(0.02, 0.18, saturation);
  return Math.max(0, 1 - keyStrength);
}

// ---------------------------------------------------------------------------
// Upload frames to Supabase Storage
// ---------------------------------------------------------------------------
async function uploadFrames(webpPaths, outfitId, onProgress) {
  for (let i = 0; i < webpPaths.length; i++) {
    const frameData = await fs.promises.readFile(webpPaths[i]);
    const remotePath = `${outfitId}/${path.basename(webpPaths[i])}`;

    const { error } = await supabase.storage
      .from('generated-outfits')
      .upload(remotePath, frameData, { contentType: 'image/webp', upsert: true });

    if (error) throw new Error(`Upload failed for ${remotePath}: ${error.message}`);
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
    .select('token')
    .eq('user_id', userId)
    .eq('platform', 'ios');

  if (!tokens || tokens.length === 0) {
    console.log(`No device tokens for user ${userId}`);
    return;
  }

  for (const { token } of tokens) {
    const note = new apn.Notification();
    note.expiry   = Math.floor(Date.now() / 1000) + 3600;
    note.badge    = 1;
    note.sound    = 'default';
    note.alert    = { title: 'Your interactive fit is ready ✨', body: 'Tap to review and add it to your archive.' };
    note.payload  = { route: 'upload' };
    note.topic    = APNS_TOPIC;

    const result = await apnProvider.send(note, token);
    if (result.failed.length > 0) {
      console.warn(`APNs failed for token ${token}:`, result.failed[0].response);
    } else {
      console.log(`Push sent to ${token}`);
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

async function falPollForResult(submitResponse, onComplete, onProgress) {
  while (true) {
    await sleep(3_000);
    const statusRes = await fetch(submitResponse.status_url, {
      headers: { 'Authorization': `Key ${FAL_API_KEY}` },
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
