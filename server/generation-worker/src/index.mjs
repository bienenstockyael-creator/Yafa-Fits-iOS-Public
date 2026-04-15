import http2 from "node:http2";
import { spawn } from "node:child_process";
import { createSign } from "node:crypto";
import { mkdtemp, mkdir, copyFile, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { createClient } from "@supabase/supabase-js";
import sharp from "sharp";

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const FAL_API_KEY = process.env.FAL_API_KEY;
const FFMPEG_BIN = process.env.FFMPEG_BIN || "ffmpeg";
const APNS_KEY_ID = process.env.APNS_KEY_ID;
const APNS_TEAM_ID = process.env.APNS_TEAM_ID;
const APNS_PRIVATE_KEY = normalizePrivateKey(process.env.APNS_PRIVATE_KEY);
const APNS_TOPIC = process.env.APNS_TOPIC || "com.yafa.Yafa";
const APNS_ENV = process.env.APNS_ENV || "production";

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !FAL_API_KEY) {
  throw new Error("Missing required environment variables.");
}

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false }
});

const INPUT_BUCKET = "generation-inputs";
const OUTPUT_BUCKET = "generated-outfits";
const FRAME_COUNT = 242;
const EXTRACTED_FRAME_COUNT = FRAME_COUNT - 1;
const FRAME_WIDTH = 323;
const FRAME_HEIGHT = 550;
const COMPOSITION_WIDTH = FRAME_WIDTH * 2;
const COMPOSITION_HEIGHT = FRAME_HEIGHT * 2;
const GREEN_SCREEN_RGB = { r: 23, g: 235, b: 79, alpha: 1 };
const COMPOSITION_WIDTH_RATIO = 0.70;
const COMPOSITION_HEIGHT_RATIO = 0.88;
const COMPOSITION_WIDTH_SAFETY_RATIO = 1.08;
const COMPOSITION_HEIGHT_SAFETY_RATIO = 1.08;
const COMPOSITION_BOUNDS_ALPHA_THRESHOLD = 1;
const COMPOSITION_BOUNDS_EXPANSION_RADIUS = 4;
const POLL_INTERVAL_MS = 3000;
const WORKER_IDLE_MS = 4000;
const FAL_QUEUE_BASE_URL = "https://queue.fal.run";
const FAL_KLING_MODEL = "fal-ai/kling-video/v2.5-turbo/pro/image-to-video";
const FAL_BRIA_MODEL = "fal-ai/bria/background/remove";
const APNS_HOST = APNS_ENV === "development" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
const APNS_PUSH_ENABLED = Boolean(APNS_KEY_ID && APNS_TEAM_ID && APNS_PRIVATE_KEY);

let cachedApnsJwt = null;
let cachedApnsJwtIssuedAt = 0;

async function main() {
  for (;;) {
    const job = await claimNextJob();
    if (!job) {
      await sleep(WORKER_IDLE_MS);
      continue;
    }

    try {
      await processJob(job);
    } catch (error) {
      console.error("Job failed", job.id, error);
      await failJob(job.id, error);
    }
  }
}

async function claimNextJob() {
  const { data: queuedJobs, error } = await supabase
    .from("generation_jobs")
    .select()
    .eq("status", "queued")
    .eq("review_state", "pending")
    .order("created_at", { ascending: true })
    .limit(1);

  if (error) {
    console.error("Failed to fetch queued jobs", error);
    return null;
  }

  const queuedJob = queuedJobs?.[0];
  if (!queuedJob) {
    return null;
  }

  const { data: claimedRows, error: claimError } = await supabase
    .from("generation_jobs")
    .update({
      status: "processing",
      stage: "removing_background",
      status_title: "Removing background",
      status_detail: "Preparing the source image with fal Bria."
    })
    .eq("id", queuedJob.id)
    .eq("status", "queued")
    .select();

  if (claimError) {
    console.error("Failed to claim job", claimError);
    return null;
  }

  return claimedRows?.[0] ?? null;
}

async function processJob(job) {
  const workDir = await mkdtemp(path.join(tmpdir(), "yafa-generation-"));

  try {
    const sourceImageData = await downloadInput(job.source_image_path);
    const klingInputPngData = isPreparedKlingInputPath(job.source_image_path)
      ? sourceImageData
      : await buildKlingInputFromSource(job.id, sourceImageData, workDir);
    const klingInputDataUri = toDataUri(klingInputPngData, "image/png");
    const videoUrl = await runKling(job.id, klingInputDataUri, job.prompt);

    await updateJob(job.id, {
      stage: "compressing",
      status_title: "Compressing",
      status_detail: "Extracting the interactive frame sequence on the server."
    });

    const videoPath = path.join(workDir, "result.mp4");
    const framesDir = path.join(workDir, "frames");
    await mkdir(framesDir, { recursive: true });

    await downloadFile(videoUrl, videoPath);
    await extractFrames(videoPath, framesDir);

    const outfit = await uploadGeneratedOutfit(job, framesDir);
    await updateJob(job.id, {
      status: "complete",
      stage: "complete",
      status_title: "Ready",
      status_detail: "Your interactive fit is ready for review.",
      completed_at: new Date().toISOString(),
      progress: 1,
      remote_outfit: outfit
    });
    await sendCompletionPush(job, outfit);
  } finally {
    await rm(workDir, { recursive: true, force: true });
  }
}

function isPreparedKlingInputPath(sourceImagePath) {
  return String(sourceImagePath || "").toLowerCase().endsWith(".png");
}

async function buildKlingInputFromSource(jobId, sourceImageData, workDir) {
  const sourceImageDataUri = toDataUri(sourceImageData, "image/jpeg");
  const cutoutPngData = await runFalBria(jobId, sourceImageDataUri);
  return prepareKlingInputImage(cutoutPngData, workDir);
}

async function downloadInput(sourceImagePath) {
  const { data, error } = await supabase.storage.from(INPUT_BUCKET).download(sourceImagePath);
  if (error) {
    throw error;
  }
  return Buffer.from(await data.arrayBuffer());
}

async function runFalBria(jobId, imageUrl) {
  await updateJob(jobId, {
    stage: "removing_background",
    status_title: "Removing background",
    status_detail: "Submitting the source image to fal Bria."
  });

  const submit = await falJsonRequest(`/${FAL_BRIA_MODEL}`, {
    method: "POST",
    body: { image_url: imageUrl }
  });

  for (;;) {
    const status = await falJsonRequest(submit.status_url, { method: "GET", absolute: true });
    const normalized = String(status.status || "").toLowerCase();
    if (normalized === "completed") {
      const result = await falJsonRequest(submit.response_url, { method: "GET", absolute: true });
      const imageUrl = Array.isArray(result.image) ? result.image[0]?.url : result.image?.url;
      if (!imageUrl) {
        throw new Error("fal Bria finished without an image URL.");
      }
      return Buffer.from(await (await fetch(imageUrl)).arrayBuffer());
    }

    if (normalized === "failed" || normalized === "error") {
      throw new Error(status.error?.message || "fal Bria failed.");
    }

    await sleep(POLL_INTERVAL_MS);
  }
}

async function runKling(jobId, imageUrl, prompt) {
  await updateJob(jobId, {
    stage: "creating_interactive_fit",
    status_title: "Creating your interactive fit",
    status_detail: "Submitting the cutout to Kling."
  });

  const submit = await falJsonRequest(`/${FAL_KLING_MODEL}`, {
    method: "POST",
    body: {
      prompt,
      image_url: imageUrl,
      tail_image_url: imageUrl,
      duration: "10"
    }
  });

  for (;;) {
    const status = await falJsonRequest(submit.status_url, { method: "GET", absolute: true });
    const normalized = String(status.status || "").toLowerCase();

    if (normalized === "completed") {
      const result = await falJsonRequest(submit.response_url, { method: "GET", absolute: true });
      const videoUrl = Array.isArray(result.video) ? result.video[0]?.url : result.video?.url;
      if (!videoUrl) {
        throw new Error("Kling finished without a video URL.");
      }
      return videoUrl;
    }

    if (normalized === "failed" || normalized === "error") {
      throw new Error(status.error?.message || "Kling generation failed.");
    }

    await sleep(POLL_INTERVAL_MS);
  }
}

async function extractFrames(videoPath, framesDir) {
  const outputPattern = path.join(framesDir, "outfit-%05d.webp");
  await runCommand(FFMPEG_BIN, [
    "-y",
    "-i",
    videoPath,
    "-vf",
    [
      "chromakey=0x17EA4F:0.12:0.05",
      "format=rgba",
      `scale=${FRAME_WIDTH}:${FRAME_HEIGHT}:force_original_aspect_ratio=decrease`,
      `pad=${FRAME_WIDTH}:${FRAME_HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=0x00000000`
    ].join(","),
    "-frames:v",
    String(EXTRACTED_FRAME_COUNT),
    outputPattern
  ]);

  const extractedFrames = (await readdir(framesDir))
    .filter(name => /^outfit-\d{5}\.webp$/.test(name))
    .sort();

  if (extractedFrames.length === 0) {
    throw new Error("ffmpeg did not produce any frame images.");
  }

  const firstExistingFrame = extractedFrames[0];
  const lastExistingFrame = extractedFrames[extractedFrames.length - 1];

  for (let index = extractedFrames.length + 1; index <= EXTRACTED_FRAME_COUNT; index += 1) {
    const targetName = `outfit-${String(index).padStart(5, "0")}.webp`;
    await copyFile(
      path.join(framesDir, lastExistingFrame),
      path.join(framesDir, targetName)
    );
  }

  const lastFramePath = path.join(framesDir, `outfit-${String(FRAME_COUNT).padStart(5, "0")}.webp`);
  await copyFile(path.join(framesDir, firstExistingFrame), lastFramePath);
}

async function prepareKlingInputImage(cutoutPngData, workDir) {
  const source = sharp(cutoutPngData, { limitInputPixels: false }).ensureAlpha();
  const { data, info } = await source.raw().toBuffer({ resolveWithObject: true });
  const subjectBounds = expandedAlphaBounds(
    data,
    info.width,
    info.height,
    info.channels,
    COMPOSITION_BOUNDS_ALPHA_THRESHOLD,
    COMPOSITION_BOUNDS_EXPANSION_RADIUS
  );

  if (!subjectBounds) {
    return source.png().toBuffer();
  }

  const scale = Math.min(
    (COMPOSITION_WIDTH * COMPOSITION_WIDTH_RATIO) / (subjectBounds.width * COMPOSITION_WIDTH_SAFETY_RATIO),
    (COMPOSITION_HEIGHT * COMPOSITION_HEIGHT_RATIO) / (subjectBounds.height * COMPOSITION_HEIGHT_SAFETY_RATIO)
  );

  const scaledWidth = Math.max(1, Math.round(info.width * scale));
  const scaledHeight = Math.max(1, Math.round(info.height * scale));
  const resizedBuffer = await source
    .resize(scaledWidth, scaledHeight, { fit: "fill", kernel: sharp.kernel.lanczos3 })
    .png()
    .toBuffer();

  const targetLeft = Math.round((COMPOSITION_WIDTH / 2) - (subjectBounds.midX * scale));
  const targetTop = Math.round((COMPOSITION_HEIGHT / 2) - (subjectBounds.midY * scale));

  const sourceCropLeft = Math.max(0, -targetLeft);
  const sourceCropTop = Math.max(0, -targetTop);
  const outputLeft = Math.max(0, targetLeft);
  const outputTop = Math.max(0, targetTop);
  const cropWidth = Math.min(scaledWidth - sourceCropLeft, COMPOSITION_WIDTH - outputLeft);
  const cropHeight = Math.min(scaledHeight - sourceCropTop, COMPOSITION_HEIGHT - outputTop);

  if (cropWidth <= 0 || cropHeight <= 0) {
    throw new Error("Prepared Kling subject placement fell outside the composition canvas.");
  }

  const compositeInput = await sharp(resizedBuffer)
    .extract({
      left: sourceCropLeft,
      top: sourceCropTop,
      width: cropWidth,
      height: cropHeight
    })
    .png()
    .toBuffer();

  const preparedPath = path.join(workDir, "kling-input.png");
  const preparedBuffer = await sharp({
    create: {
      width: COMPOSITION_WIDTH,
      height: COMPOSITION_HEIGHT,
      channels: 4,
      background: GREEN_SCREEN_RGB
    }
  })
    .composite([{ input: compositeInput, left: outputLeft, top: outputTop }])
    .png()
    .toBuffer();

  await writeFile(preparedPath, preparedBuffer);
  return preparedBuffer;
}

async function uploadGeneratedOutfit(job, framesDir) {
  const outfitId = `outfit-${job.outfit_num}`;
  const assetVersion = `${outfitId}-${job.id}`;
  const folder = `${job.user_id}/${assetVersion}`;
  const prefix = `${assetVersion}_`;

  for (let index = 1; index <= FRAME_COUNT; index += 1) {
    const frameName = `outfit-${String(index).padStart(5, "0")}.webp`;
    const frameData = await readFile(path.join(framesDir, frameName));
    const remoteFrameName = `${folder}/${prefix}${String(index - 1).padStart(5, "0")}.webp`;

    const { error } = await supabase.storage
      .from(OUTPUT_BUCKET)
      .upload(remoteFrameName, frameData, {
        upsert: true,
        contentType: "image/webp"
      });

    if (error) {
      throw error;
    }
  }

  return {
    id: outfitId,
    name: `Outfit ${job.outfit_num}`,
    date: new Date().toISOString().slice(0, 10),
    frameCount: FRAME_COUNT,
    folder,
    prefix,
    frameExt: "webp",
    remoteBaseURL: `${SUPABASE_URL}/storage/v1/object/public/${OUTPUT_BUCKET}`,
    scale: 1,
    isRotationReversed: false,
    tags: [],
    activity: null,
    weather: null,
    products: [],
    caption: null
  };
}

async function updateJob(jobId, values) {
  const { error } = await supabase
    .from("generation_jobs")
    .update(values)
    .eq("id", jobId);

  if (error) {
    throw error;
  }
}

async function failJob(jobId, error) {
  try {
    await updateJob(jobId, {
      status: "failed",
      stage: "failed",
      status_title: "Generation failed",
      status_detail: error instanceof Error ? error.message : String(error),
      error: error instanceof Error ? error.message : String(error)
    });
  } catch (updateError) {
    console.error("Failed to mark job failed", updateError);
  }
}

async function sendCompletionPush(job, outfit) {
  if (!APNS_PUSH_ENABLED) {
    return;
  }

  const { data: tokens, error } = await supabase
    .from("device_push_tokens")
    .select("token, environment, bundle_identifier")
    .eq("user_id", job.user_id)
    .eq("platform", "ios");

  if (error) {
    console.error("Failed to fetch push tokens", error);
    return;
  }

  const matchingTokens = (tokens || []).filter(tokenRow =>
    tokenRow.environment === APNS_ENV && tokenRow.bundle_identifier === APNS_TOPIC
  );

  await Promise.allSettled(
    matchingTokens.map(tokenRow =>
      postApnsNotification(tokenRow.token, {
        aps: {
          alert: {
            title: "Your fit is ready",
            body: "Your interactive outfit is ready for review."
          },
          badge: 1,
          sound: "default"
        },
        type: "generation_complete",
        generationJobId: job.id,
        outfitId: outfit.id
      })
    )
  );
}

async function postApnsNotification(deviceToken, payload) {
  const client = http2.connect(APNS_HOST);

  try {
    const jwt = createApnsJwt();
    await new Promise((resolve, reject) => {
      const request = client.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        authorization: `bearer ${jwt}`,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": APNS_TOPIC,
        "content-type": "application/json"
      });

      let responseBody = "";
      let statusCode = 0;

      request.setEncoding("utf8");
      request.on("response", headers => {
        statusCode = Number(headers[http2.constants.HTTP2_HEADER_STATUS] || 0);
      });
      request.on("data", chunk => {
        responseBody += chunk;
      });
      request.on("end", () => {
        if (statusCode >= 200 && statusCode < 300) {
          resolve();
        } else {
          reject(new Error(`APNs ${statusCode}: ${responseBody || "Unknown error"}`));
        }
      });
      request.on("error", reject);
      request.end(JSON.stringify(payload));
    });
  } catch (error) {
    console.error("Failed to send APNs notification", deviceToken, error);
  } finally {
    client.close();
  }
}

function createApnsJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedApnsJwt && now - cachedApnsJwtIssuedAt < 50 * 60) {
    return cachedApnsJwt;
  }

  const header = toBase64Url(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID }));
  const claims = toBase64Url(JSON.stringify({ iss: APNS_TEAM_ID, iat: now }));
  const signer = createSign("sha256");
  signer.update(`${header}.${claims}`);
  signer.end();

  const signature = signer.sign(APNS_PRIVATE_KEY);
  cachedApnsJwt = `${header}.${claims}.${toBase64Url(signature)}`;
  cachedApnsJwtIssuedAt = now;
  return cachedApnsJwt;
}

async function falJsonRequest(url, { method, body = undefined, absolute = false }) {
  const targetUrl = absolute ? url : `${FAL_QUEUE_BASE_URL}${url.startsWith("/") ? "" : "/"}${url}`;
  const response = await fetch(targetUrl, {
    method,
    headers: {
      Authorization: `Key ${FAL_API_KEY}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  });

  if (!response.ok) {
    throw new Error(await response.text());
  }

  return response.json();
}

async function downloadFile(url, filePath) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to download ${url}: ${response.status}`);
  }

  const data = Buffer.from(await response.arrayBuffer());
  await writeFile(filePath, data);
}

async function runCommand(command, args) {
  await new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stderr = "";

    child.stderr.on("data", chunk => {
      stderr += chunk.toString();
    });

    child.on("error", reject);
    child.on("close", code => {
      if (code === 0) {
        resolve(undefined);
      } else {
        reject(new Error(stderr || `${command} exited with code ${code}`));
      }
    });
  });
}

function toDataUri(data, mimeType) {
  return `data:${mimeType};base64,${Buffer.from(data).toString("base64")}`;
}

function toBase64Url(value) {
  const buffer = Buffer.isBuffer(value) ? value : Buffer.from(value);
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function normalizePrivateKey(key) {
  if (!key) {
    return null;
  }
  return key.includes("\\n") ? key.replace(/\\n/g, "\n") : key;
}

function expandedAlphaBounds(rgbaData, width, height, channels, alphaThreshold, expansionRadius) {
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const alpha = rgbaData[(y * width + x) * channels + 3];
      if (alpha <= alphaThreshold) {
        continue;
      }
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }

  if (maxX < minX || maxY < minY) {
    return null;
  }

  minX = Math.max(0, minX - expansionRadius);
  minY = Math.max(0, minY - expansionRadius);
  maxX = Math.min(width - 1, maxX + expansionRadius);
  maxY = Math.min(height - 1, maxY + expansionRadius);

  const boundsWidth = maxX - minX + 1;
  const boundsHeight = maxY - minY + 1;

  return {
    x: minX,
    y: minY,
    width: boundsWidth,
    height: boundsHeight,
    midX: minX + boundsWidth / 2,
    midY: minY + boundsHeight / 2
  };
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
