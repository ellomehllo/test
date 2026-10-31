// POST { productId, purchaseToken } with the signed-in user's token → checks the Google Play purchase with the Play
// Developer API and credits the Bhakti tokens. Answers { status: 'credited', tokens } (tokens is 0 when this purchase
// was already credited) or an error. The app consumes the Play purchase only after 'credited', so a failed check is
// retried on the next launch. Secret: PLAY_SERVICE_ACCOUNT, a service-account JSON key that Play Console lets view
// financial data and manage orders (falls back to FCM_SERVICE_ACCOUNT when that same account was given Play access).
import { createClient } from 'npm:@supabase/supabase-js@2';

const PACKAGE = 'online.vanarsathi.app';
const PRODUCTS = ['tokens_50', 'tokens_150', 'tokens_350', 'tokens_800'];
const API = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE}/purchases/products/`;
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const b64url = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));
// a PEM key's body as bytes, however the secret was pasted
const pemBytes = (pem: string) => Uint8Array.from(atob(pem.replace(/-----[^-]*-----/g, '').replace(/\\n/g, '').replace(/[^A-Za-z0-9+/=]/g, '')), c => c.charCodeAt(0));

// a service-account JWT (RS256) exchanged for a one-hour OAuth access token to the Play Developer API
let cached: { token: string; until: number } | null = null;
async function playToken(): Promise<string> {
  if (cached && cached.until > Date.now()) return cached.token;
  const raw = Deno.env.get('PLAY_SERVICE_ACCOUNT') || Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!raw) throw new Error('PLAY_SERVICE_ACCOUNT not set');
  const sa = JSON.parse(raw);
  const key = await crypto.subtle.importKey('pkcs8', pemBytes(String(sa.private_key)), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const now = Math.floor(Date.now() / 1000);
  const head = enc({ alg: 'RS256', typ: 'JWT' });
  const claims = enc({ iss: sa.client_email, scope: 'https://www.googleapis.com/auth/androidpublisher', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 });
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${head}.${claims}`));
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claims}.${b64url(sig)}` })
  });
  const j = await r.json();
  if (!j.access_token) throw new Error('Google login failed: ' + (j.error_description || j.error || r.status));
  cached = { token: j.access_token, until: Date.now() + 50 * 60 * 1000 };
  return j.access_token;
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return reply({ error: 'POST only' }, 405);
  const url = Deno.env.get('SUPABASE_URL')!;
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }
  });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return reply({ error: 'sign in first' }, 401);

  let productId = '', purchaseToken = '';
  try { ({ productId = '', purchaseToken = '' } = await req.json()); } catch (_) { /* answered below */ }
  try {
    if (!PRODUCTS.includes(productId) || !purchaseToken) throw new Error('missing or unknown product');
    const auth = { Authorization: `Bearer ${await playToken()}` };
    const path = API + encodeURIComponent(productId) + '/tokens/' + encodeURIComponent(purchaseToken);
    const r = await fetch(path, { headers: auth });
    const p = await r.json();
    if (!r.ok) throw new Error('Play: ' + (p.error?.message || r.status));
    // 0 purchased, 1 cancelled, 2 pending; the account id was set by the app to the Supabase user id
    if (p.purchaseState !== 0) throw new Error('purchase not completed (state ' + p.purchaseState + ')');
    if (p.obfuscatedExternalAccountId !== user.id) throw new Error('purchase belongs to another account');
    // purchaseType 0 is a license tester's test purchase: credited like App Store sandbox purchases, no real money
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data, error } = await admin.rpc('credit_purchase', { p_user: user.id, p_store: 'play', p_product: productId, p_order: p.orderId || `play:${purchaseToken}` });
    if (error) throw new Error(error.message);
    // acknowledge here too, so Play never refunds it if the phone goes offline before consuming
    if (p.acknowledgementState === 0) await fetch(path + ':acknowledge', { method: 'POST', headers: auth }).catch(() => {});
    return reply({ status: 'credited', tokens: data ?? 0, productId });
  } catch (e) {
    console.warn('[google-purchase]', user.id, e instanceof Error ? e.message : e);
    return reply({ error: e instanceof Error ? e.message : 'purchase check failed' }, 400);
  }
});
