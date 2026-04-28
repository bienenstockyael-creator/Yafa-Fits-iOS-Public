#!/usr/bin/env node
// Compare FAL image-edit models for product-thumbnail generation.
//
// Usage:
//   FAL_API_KEY=... node compare.mjs <image-url> [prompt]
//
// Pass a publicly reachable URL to a cropped clothing segment (e.g., a jacket
// from one of your selfies, hosted in Supabase storage). The script calls
// several FAL models in parallel and saves their outputs side-by-side so you
// can compare quality.

import { writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const FAL_API_KEY = process.env.FAL_API_KEY;
if (!FAL_API_KEY) {
  console.error('Set FAL_API_KEY env var first.');
  process.exit(1);
}

const inputImage = process.argv[2];
const prompt = process.argv[3] || [
  'Professional flat-lay product photograph of this single garment.',
  'Clean white background, studio lighting, no body, no model, no skin showing.',
  'Garment laid flat or on an invisible mannequin, e-commerce catalog style.',
].join(' ');

if (!inputImage) {
  console.error('Usage: node compare.mjs <image-url> [prompt]');
  process.exit(1);
}

// Models to compare. Endpoints + request bodies follow FAL's queue API.
// If any endpoint changes, update the URL here.
const MODELS = [
  {
    name: 'nano-banana-edit',
    endpoint: 'https://queue.fal.run/fal-ai/nano-banana/edit',
    body: { prompt, image_urls: [inputImage] },
    extractUrl: r => r.images?.[0]?.url,
  },
  {
    name: 'flux-kontext-pro',
    endpoint: 'https://queue.fal.run/fal-ai/flux-pro/kontext',
    body: { prompt, image_url: inputImage, num_images: 1 },
    extractUrl: r => r.images?.[0]?.url,
  },
  {
    name: 'bria-product-shot',
    endpoint: 'https://queue.fal.run/fal-ai/bria/product-shot',
    body: { image_url: inputImage, scene_description: 'clean white studio background, flat-lay product photography' },
    extractUrl: r => r.images?.[0]?.url || r.image?.url,
  },
  {
    name: 'recraft-v3-i2i',
    endpoint: 'https://queue.fal.run/fal-ai/recraft/v3/image-to-image',
    body: { image_url: inputImage, prompt, strength: 0.8, style: 'realistic_image' },
    extractUrl: r => r.images?.[0]?.url,
  },
];

const POLL_INTERVAL_MS = 2000;
const TIMEOUT_MS = 5 * 60 * 1000;

const headers = {
  'Authorization': `Key ${FAL_API_KEY}`,
  'Content-Type': 'application/json',
};

async function callModel({ name, endpoint, body, extractUrl }) {
  const t0 = Date.now();

  const submit = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify(body) });
  if (!submit.ok) {
    throw new Error(`${name} submit ${submit.status}: ${await submit.text()}`);
  }
  const { status_url, response_url, request_id } = await submit.json();
  console.log(`[${name}] queued (${request_id})`);

  const deadline = Date.now() + TIMEOUT_MS;
  let lastStatus = '';
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, POLL_INTERVAL_MS));
    const s = await (await fetch(status_url, { headers })).json();
    if (s.status !== lastStatus) {
      console.log(`[${name}] status: ${s.status}`);
      lastStatus = s.status;
    }
    if (s.status === 'COMPLETED') break;
    if (s.status === 'FAILED' || s.status === 'ERROR') {
      throw new Error(`${name} failed: ${JSON.stringify(s).slice(0, 400)}`);
    }
  }

  const result = await (await fetch(response_url, { headers })).json();
  const url = extractUrl(result);
  if (!url) {
    throw new Error(`${name}: no image url in response: ${JSON.stringify(result).slice(0, 400)}`);
  }

  const imgRes = await fetch(url);
  if (!imgRes.ok) throw new Error(`${name}: download ${imgRes.status}`);
  const buf = Buffer.from(await imgRes.arrayBuffer());

  const outDir = join(dirname(fileURLToPath(import.meta.url)), 'output');
  await mkdir(outDir, { recursive: true });
  const outPath = join(outDir, `${name}.png`);
  await writeFile(outPath, buf);

  return { name, ms: Date.now() - t0, path: outPath, bytes: buf.length };
}

console.log(`Input: ${inputImage}`);
console.log(`Prompt: ${prompt}\n`);

const results = await Promise.allSettled(MODELS.map(callModel));

console.log('\n=== Results ===');
for (const r of results) {
  if (r.status === 'fulfilled') {
    const { name, ms, path, bytes } = r.value;
    console.log(`OK   ${name.padEnd(22)}  ${(ms / 1000).toFixed(1)}s  ${(bytes / 1024).toFixed(0)}KB  ${path}`);
  } else {
    console.log(`FAIL ${r.reason.message}`);
  }
}
console.log(`\nOpen ./output/ to view side-by-side.`);
