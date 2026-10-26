// POST { title, body, userId? } with header x-push-secret → sends a push to everyone (or one account): iPhones through
// Apple's push service, Android phones through Firebase Cloud Messaging. Secrets (supabase secrets set …): PUSH_SECRET
// (guards this function), APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8 (the .p8 file's text) for iPhone, and
// FCM_SERVICE_ACCOUNT (the Firebase service-account JSON) for Android. TestFlight and App Store builds use production APNs.
import { createClient } from 'npm:@supabase/supabase-js@2';

const BUNDLE_ID = 'online.vanarsathi.app';
const APNS = 'https://api.push.apple.com/3/device/';
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });
const b64url = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

// APNs accepts a JWT signed with the .p8 key (ES256), valid up to an hour
async function apnsJwt(): Promise<string> {
  const pem = Deno.env.get('APNS_KEY_P8')!.replace(/-----[^-]+-----|\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const head = enc({ alg: 'ES256', kid: Deno.env.get('APNS_KEY_ID') }), claims = enc({ iss: Deno.env.get('APNS_TEAM_ID'), iat: Math.floor(Date.now() / 1000) });
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(`${head}.${claims}`));
  return `${head}.${claims}.${b64url(sig)}`;
}

// Firebase: a service-account JWT (RS256) exchanged for a one-hour OAuth access token
async function fcmAuth(): Promise<{ token: string; project: string } | null> {
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!raw) return null;
  const sa = JSON.parse(raw);
  const pem = String(sa.private_key).replace(/-----[^-]+-----|\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const now = Math.floor(Date.now() / 1000);
  const head = enc({ alg: 'RS256', typ: 'JWT' });
  const claims = enc({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 });
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${claims}`));
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claims}.${b64url(sig)}` })
  });
  const j = await r.json();
  if (!j.access_token) throw new Error('Firebase login failed: ' + (j.error_description || j.error || r.status));
  return { token: j.access_token, project: sa.project_id };
}

Deno.serve(async req => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const secret = Deno.env.get('PUSH_SECRET');
  if (!secret || req.headers.get('x-push-secret') !== secret) return json({ error: 'not allowed' }, 401);
  let msg: { title?: string; body?: string; userId?: string } = {};
  try { msg = await req.json(); } catch (_) { /* checked below */ }
  if (!msg.title || !msg.body) return json({ error: 'title and body needed' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let q = db.from('push_tokens').select('token, platform');
  if (msg.userId) q = q.eq('user_id', msg.userId);
  const { data: rows, error } = await q;
  if (error) return json({ error: error.message }, 500);

  const ios = (rows ?? []).filter(r => r.platform !== 'android'), android = (rows ?? []).filter(r => r.platform === 'android');
  const jwt = ios.length ? await apnsJwt() : '';
  const payload = JSON.stringify({ aps: { alert: { title: msg.title, body: msg.body }, sound: 'default' } });
  let sent = 0, failed = 0; const gone: string[] = [], reasons: Record<string, number> = {};
  const fcm = android.length ? await fcmAuth() : null;
  if (android.length && !fcm) { failed += android.length; reasons['FCM_SERVICE_ACCOUNT not set'] = android.length; }
  for (const { token } of fcm ? android : []) {
    const r = await fetch(`https://fcm.googleapis.com/v1/projects/${fcm!.project}/messages:send`, {
      method: 'POST', headers: { authorization: `Bearer ${fcm!.token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ message: { token, notification: { title: msg.title, body: msg.body }, android: { priority: 'high' } } })
    });
    if (r.ok) { sent++; continue; }
    failed++;
    const err = (await r.json().catch(() => ({}))).error || {};
    const reason = ((err.details || []).find((d: any) => d.errorCode) || {}).errorCode || err.status || String(r.status);
    reasons[reason] = (reasons[reason] || 0) + 1;
    if (reason === 'UNREGISTERED' || r.status === 404) gone.push(token);
  }
  for (const { token } of ios) {
    const r = await fetch(APNS + token, {
      method: 'POST', body: payload,
      headers: { authorization: `bearer ${jwt}`, 'apns-topic': BUNDLE_ID, 'apns-push-type': 'alert', 'apns-priority': '10' }
    });
    if (r.ok) { sent++; continue; }
    failed++;
    const reason = (await r.json().catch(() => ({}))).reason || String(r.status);
    reasons[reason] = (reasons[reason] || 0) + 1;
    if (r.status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered') gone.push(token);
  }
  if (gone.length) await db.from('push_tokens').delete().in('token', gone);
  return json({ phones: rows?.length ?? 0, iphones: ios.length, androids: android.length, sent, failed, reasons, removed: gone.length });
});
