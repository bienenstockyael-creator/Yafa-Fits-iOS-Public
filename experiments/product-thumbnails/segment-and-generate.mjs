#!/usr/bin/env node
// End-to-end validation: SAM2 point-prompt → masked crop → nano-banana thumbnail.
//
// Simulates a user tapping at (x, y) on a clothing item in their selfie. SAM2
// returns the segment mask for that point, we apply the mask + crop to the
// bounding box, and feed the result to nano-banana to produce a flat-lay
// product thumbnail.
//
// Usage:
//   FAL_API_KEY=... node segment-and-generate.mjs <image-url> <x> <y> [label]
//
// Where x/y are pixel coordinates (0,0 = top-left) of the tap point on the
// original image. `label` is what the user typed for that garment (e.g.
// "Black Jacket"); used in the nano-banana prompt.

import { writeFile, mkdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import sharp from 'sharp';

const FAL_API_KEY = process.env.FAL_API_KEY;
if (!FAL_API_KEY) {
  console.error('Set FAL_API_KEY env var first.');
  process.exit(1);
}

const inputImage = process.argv[2];
const x = Number(process.argv[3]);
const y = Number(process.argv[4]);
const label = process.argv[5] || 'garment';

if (!inputImage || !Number.isFinite(x) || !Number.isFinite(y)) {
  console.error('Usage: node segment-and-generate.mjs <image-url> <x> <y> [label]');
  process.exit(1);
}

const SAM2_ENDPOINT = 'https://queue.fal.run/fal-ai/sam2/image';
const NANO_BANANA_ENDPOINT = 'https://queue.fal.run/fal-ai/nano-banana/edit';
const POLL_INTERVAL_MS = 2000;
const TIMEOUT_MS = 5 * 60 * 1000;

const headers = {
  'Authorization': `Key ${FAL_API_KEY}`,
  'Content-Type': 'application/json',
};

const outDir = join(dirname(fileURLToPath(import.meta.url)), 'output-pipeline');
await mkdir(outDir, { recursive: true });

async function falQueueCall(endpoint, body, label) {
  const t0 = Date.now();
  console.log(`\n[${label}] submitting...`);
  const submit = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!submit.ok) throw new Error(`${label} submit ${submit.status}: ${await submit.text()}`);
  const { status_url, response_url, request_id } = await submit.json();
  console.log(`[${label}] queued (${request_id})`);

  const deadline = Date.now() + TIMEOUT_MS;
  let lastStatus = '';
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
    const s = await (await fetch(status_url, { headers })).json();
    if (s.status !== lastStatus) {
      console.log(`[${label}] status: ${s.status}`);
      lastStatus = s.status;
    }
    if (s.status === 'COMPLETED') break;
    if (s.status === 'FAILED' || s.status === 'ERROR') {
      throw new Error(`${label} failed: ${JSON.stringify(s).slice(0, 600)}`);
    }
  }
  const result = await (await fetch(response_url, { headers })).json();
  console.log(`[${label}] done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  return result;
}

async function downloadToBuffer(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`download ${url} → ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

// --- Step 1: SAM2 with point prompt ---
console.log(`Input: ${inputImage}`);
console.log(`Tap point: (${x}, ${y})  Label: "${label}"`);

const samResult = await falQueueCall(SAM2_ENDPOINT, {
  image_url: inputImage,
  prompts: [{ type: 'point', x, y, label: 1 }],
}, 'sam2');
await writeFile(join(outDir, 'sam2_response.json'), JSON.stringify(samResult, null, 2));

// SAM2 typically returns { image: { url } } where the image is the colored mask
// composited over the original, plus { individual_masks } if multiple. Find a
// usable mask URL.
const maskUrl =
  samResult.individual_masks?.[0]?.url ||
  samResult.individual_masks?.[0] ||
  samResult.mask?.url ||
  samResult.image?.url ||
  samResult.images?.[0]?.url;
if (!maskUrl) {
  console.error('Could not find mask URL in SAM2 response. Keys:', Object.keys(samResult));
  console.error(JSON.stringify(samResult, null, 2).slice(0, 1500));
  process.exit(1);
}
console.log(`mask URL: ${maskUrl}`);

const [originalBuf, maskBuf] = await Promise.all([
  downloadToBuffer(inputImage),
  downloadToBuffer(maskUrl),
]);
await writeFile(join(outDir, 'original.png'), originalBuf);
await writeFile(join(outDir, 'sam2_mask.png'), maskBuf);

// --- Step 2: apply mask + crop tightly to bounding box ---
console.log(`\n[crop] applying mask and cropping to bbox...`);

const original = sharp(originalBuf);
const origMeta = await original.metadata();
console.log(`[crop] original size: ${origMeta.width}x${origMeta.height}`);

// Normalize the mask to match the original image dimensions and convert to a
// single-channel alpha. Threshold at midpoint so it's strictly binary.
const maskAligned = await sharp(maskBuf)
  .resize(origMeta.width, origMeta.height, { fit: 'fill' })
  .greyscale()
  .threshold(128)
  .toBuffer();

// Compose the original through the mask (alpha = mask). Pixels outside the
// mask become transparent.
const masked = await sharp(originalBuf)
  .ensureAlpha()
  .joinChannel(maskAligned)
  .png()
  .toBuffer();
await writeFile(join(outDir, 'masked.png'), masked);

// Find the bounding box of the masked region by inspecting raw alpha values.
const { data: alphaData, info: alphaInfo } = await sharp(maskAligned)
  .raw()
  .toBuffer({ resolveWithObject: true });
let minX = alphaInfo.width, minY = alphaInfo.height, maxX = -1, maxY = -1;
for (let py = 0; py < alphaInfo.height; py++) {
  for (let px = 0; px < alphaInfo.width; px++) {
    if (alphaData[py * alphaInfo.width + px] > 0) {
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;
    }
  }
}
if (maxX < 0) {
  console.error('[crop] mask is empty — SAM2 did not segment anything at that point.');
  process.exit(1);
}
// Pad the bbox by 5% so the garment edges aren't cut off.
const padX = Math.round((maxX - minX) * 0.05);
const padY = Math.round((maxY - minY) * 0.05);
const cropX = Math.max(0, minX - padX);
const cropY = Math.max(0, minY - padY);
const cropW = Math.min(alphaInfo.width - cropX, (maxX - minX) + 2 * padX + 1);
const cropH = Math.min(alphaInfo.height - cropY, (maxY - minY) + 2 * padY + 1);
console.log(`[crop] bbox: (${cropX},${cropY}) ${cropW}x${cropH}`);

const cropped = await sharp(masked)
  .extract({ left: cropX, top: cropY, width: cropW, height: cropH })
  .png()
  .toBuffer();
const croppedPath = join(outDir, 'cropped.png');
await writeFile(croppedPath, cropped);

// --- Step 3: send cropped image to nano-banana ---
// nano-banana expects a URL. Use a base64 data URI so we don't need to upload
// anywhere.
const croppedDataURI = `data:image/png;base64,${cropped.toString('base64')}`;
const prompt = [
  `Professional flat-lay product photograph of this single ${label}.`,
  'Clean white background, studio lighting, no body, no model, no skin showing.',
  'The garment laid flat or on an invisible mannequin, e-commerce catalog style.',
].join(' ');

const nanoResult = await falQueueCall(NANO_BANANA_ENDPOINT, {
  prompt,
  image_urls: [croppedDataURI],
}, 'nano-banana');
await writeFile(join(outDir, 'nano_response.json'), JSON.stringify(nanoResult, null, 2));

const thumbUrl = nanoResult.images?.[0]?.url;
if (!thumbUrl) {
  console.error('No thumbnail URL in nano-banana response:');
  console.error(JSON.stringify(nanoResult, null, 2).slice(0, 1500));
  process.exit(1);
}
const thumbBuf = await downloadToBuffer(thumbUrl);
await writeFile(join(outDir, 'thumbnail.png'), thumbBuf);

console.log(`\n=== Done ===`);
console.log(`  output-pipeline/original.png     — your selfie`);
console.log(`  output-pipeline/sam2_mask.png    — what SAM2 segmented from your tap`);
console.log(`  output-pipeline/masked.png       — original with everything else made transparent`);
console.log(`  output-pipeline/cropped.png      — tight crop fed to nano-banana`);
console.log(`  output-pipeline/thumbnail.png    — final flat-lay thumbnail`);
console.log(`\nOpen ./output-pipeline/ in Finder to inspect each step.`);
