#!/usr/bin/env node
// Test FAL SAM2 auto-segmentation on a full outfit selfie.
//
// Usage:
//   FAL_API_KEY=... node segment.mjs <image-url>
//
// Calls FAL's SAM2 auto-segment endpoint to detect every distinct region in
// the image, then downloads each segment mask + a composite preview to
// ./output-segments/. We can inspect the result to see whether SAM cleanly
// separates jacket / pants / shoes / bag, or whether it over- or under-segments.

import { writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const FAL_API_KEY = process.env.FAL_API_KEY;
if (!FAL_API_KEY) {
  console.error('Set FAL_API_KEY env var first.');
  process.exit(1);
}

const inputImage = process.argv[2];
if (!inputImage) {
  console.error('Usage: node segment.mjs <image-url>');
  process.exit(1);
}

const ENDPOINT = 'https://queue.fal.run/fal-ai/sam2/auto-segment';
const POLL_INTERVAL_MS = 2000;
const TIMEOUT_MS = 5 * 60 * 1000;

const headers = {
  'Authorization': `Key ${FAL_API_KEY}`,
  'Content-Type': 'application/json',
};

console.log(`Input: ${inputImage}\n`);

const submit = await fetch(ENDPOINT, {
  method: 'POST',
  headers,
  body: JSON.stringify({ image_url: inputImage }),
});
if (!submit.ok) {
  console.error(`Submit failed ${submit.status}: ${await submit.text()}`);
  process.exit(1);
}
const { status_url, response_url, request_id } = await submit.json();
console.log(`queued (${request_id})`);

const deadline = Date.now() + TIMEOUT_MS;
let lastStatus = '';
while (Date.now() < deadline) {
  await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
  const s = await (await fetch(status_url, { headers })).json();
  if (s.status !== lastStatus) {
    console.log(`status: ${s.status}`);
    lastStatus = s.status;
  }
  if (s.status === 'COMPLETED') break;
  if (s.status === 'FAILED' || s.status === 'ERROR') {
    console.error(`Failed: ${JSON.stringify(s).slice(0, 600)}`);
    process.exit(1);
  }
}

const result = await (await fetch(response_url, { headers })).json();

const outDir = join(dirname(fileURLToPath(import.meta.url)), 'output-segments');
await mkdir(outDir, { recursive: true });
await writeFile(join(outDir, '_response.json'), JSON.stringify(result, null, 2));
console.log(`\nSaved raw response → output-segments/_response.json`);

// Heuristically download whatever images the response contains. SAM2 auto-segment
// typically returns either a `combined_mask` URL plus per-segment data, or an
// `individual_masks` array. We download every URL we can find.
const downloaded = [];
async function tryDownload(url, name) {
  try {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    const path = join(outDir, name);
    await writeFile(path, buf);
    downloaded.push({ name, bytes: buf.length });
  } catch (e) {
    console.error(`download ${name} failed: ${e.message}`);
  }
}

if (typeof result.combined_mask?.url === 'string') {
  await tryDownload(result.combined_mask.url, 'combined_mask.png');
} else if (typeof result.combined_mask === 'string') {
  await tryDownload(result.combined_mask, 'combined_mask.png');
}

const masks = result.individual_masks || result.masks || result.segments || [];
for (let i = 0; i < masks.length; i++) {
  const m = masks[i];
  const url = typeof m === 'string' ? m : (m?.url || m?.mask?.url || m?.image?.url);
  if (url) await tryDownload(url, `mask_${String(i).padStart(2, '0')}.png`);
}

console.log(`\n=== Downloaded ${downloaded.length} files ===`);
for (const d of downloaded) {
  console.log(`  ${d.name}  ${(d.bytes / 1024).toFixed(0)}KB`);
}
console.log(`\nOpen ./output-segments/ to inspect.`);
console.log(`\nKey response keys: ${Object.keys(result).join(', ')}`);
