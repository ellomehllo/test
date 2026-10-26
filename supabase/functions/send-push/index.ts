// POST { title, body, userId? } with header x-push-secret → sends an iPhone push to everyone (or one account) through
// Apple's push service. Secrets (supabase secrets set …): PUSH_SECRET (any long random string, guards this function),
// APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8 (the .p8 file's text). TestFlight and App Store builds use production APNs.
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

Deno.serve(async req => {
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const secret = Deno.env.get('PUSH_SECRET');
  if (!secret || req.headers.get('x-push-secret') !== secret) return json({ error: 'not allowed' }, 401);
  let msg: { title?: string; body?: string; userId?: string } = {};
  try { msg = await req.json(); } catch (_) { /* checked below */ }
  if (!msg.title || !msg.body) return json({ error: 'title and body needed' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let q = db.from('push_tokens').select('token');
  if (msg.userId) q = q.eq('user_id', msg.userId);
  const { data: rows, error } = await q;
  if (error) return json({ error: error.message }, 500);

  const jwt = await apnsJwt();
  const payload = JSON.stringify({ aps: { alert: { title: msg.title, body: msg.body }, sound: 'default' } });
  let sent = 0, failed = 0; const gone: string[] = [], reasons: Record<string, number> = {};
  for (const { token } of rows ?? []) {
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
  return json({ phones: rows?.length ?? 0, sent, failed, reasons, removed: gone.length });
});
