/**
 * Yafa Notification Worker
 *
 * Polls for new likes, comments, and follows every 10 seconds
 * and sends APNs push notifications to affected users.
 * Runs independently from the generation worker.
 */

import { createClient } from '@supabase/supabase-js';
import apn from '@parse/node-apn';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { autoRefreshToken: false, persistSession: false } }
);

const apnTokenConfig = {
  key:    process.env.APNS_PRIVATE_KEY,
  keyId:  process.env.APNS_KEY_ID,
  teamId: process.env.APNS_TEAM_ID,
};
const apnProviderDev  = new apn.Provider({ token: apnTokenConfig, production: false });
const apnProviderProd = new apn.Provider({ token: apnTokenConfig, production: true  });
apnProviderDev.on('error',  (err) => console.error('APNs dev error:', err));
apnProviderProd.on('error', (err) => console.error('APNs prod error:', err));
const APNS_TOPIC = process.env.APNS_TOPIC || 'com.yafa.Yafa';

let lastCheck = new Date().toISOString();

console.log('Yafa notification worker starting…');
console.log('  SUPABASE_URL:', process.env.SUPABASE_URL ? 'set' : 'MISSING');
console.log('  APNS_KEY_ID:', process.env.APNS_KEY_ID || 'MISSING');

await pollLoop();

async function pollLoop() {
  while (true) {
    try {
      await checkSocialActivity();
    } catch (err) {
      console.error('Poll error:', err.message);
    }
    await sleep(10_000);
  }
}

async function checkSocialActivity() {
  const since = lastCheck;
  lastCheck = new Date().toISOString();

  // New likes
  const { data: likes } = await supabase
    .from('likes')
    .select('user_id, outfit_id')
    .gt('created_at', since);

  for (const like of likes ?? []) {
    const { data: outfit } = await supabase
      .from('outfits')
      .select('user_id')
      .eq('id', like.outfit_id)
      .single();
    if (outfit && outfit.user_id !== like.user_id) {
      await sendPush(outfit.user_id, 'New like ❤️', 'Someone liked your outfit!');
    }
  }

  // New comments
  const { data: comments } = await supabase
    .from('comments')
    .select('user_id, outfit_id, body')
    .gt('created_at', since);

  for (const comment of comments ?? []) {
    const { data: outfit } = await supabase
      .from('outfits')
      .select('user_id')
      .eq('id', comment.outfit_id)
      .single();
    if (outfit && outfit.user_id !== comment.user_id) {
      const preview = (comment.body || '').slice(0, 80) || 'Someone commented on your outfit!';
      await sendPush(outfit.user_id, 'New comment 💬', preview);
    }
  }

  // New follows
  const { data: follows } = await supabase
    .from('follows')
    .select('follower_id, following_id')
    .gt('created_at', since);

  for (const follow of follows ?? []) {
    if (follow.follower_id !== follow.following_id) {
      await sendPush(follow.following_id, 'New follower 🙌', 'Someone started following you!');
    }
  }
}

async function sendPush(userId, title, body) {
  const { data: tokens } = await supabase
    .from('device_push_tokens')
    .select('token, environment')
    .eq('user_id', userId)
    .eq('platform', 'ios');

  if (!tokens || tokens.length === 0) return;

  for (const { token, environment } of tokens) {
    const note = new apn.Notification();
    note.expiry = Math.floor(Date.now() / 1000) + 3600;
    note.badge  = 1;
    note.sound  = 'default';
    note.alert  = { title, body };
    note.topic  = APNS_TOPIC;

    const provider = environment === 'production' ? apnProviderProd : apnProviderDev;
    const result = await provider.send(note, token);
    if (result.failed.length > 0) {
      console.warn(`APNs failed for ${token.slice(0, 12)}:`, result.failed[0].response);
    }
  }
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
