// POST { jws } with the signed-in user's token → checks the App Store purchase and credits the Bhakti tokens.
// Answers { status: 'credited', tokens } (tokens is 0 when this purchase was already credited), { status: 'test' }
// for purchases made with Xcode's StoreKit test file (never credited), or an error. The app finishes the StoreKit
// transaction only after 'credited' or 'test', so a failed check is retried on the next launch.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { checkTransaction, peek, verifyAppleJws } from './verify.ts';

const BUNDLE_ID = 'online.vanarsathi.app';
const PRODUCTS = ['tokens_50', 'tokens_150', 'tokens_350', 'tokens_800'];
// App Review buys with sandbox accounts, so Sandbox purchases are credited too (with real tokens, but no real money)
const ENVIRONMENTS = ['Production', 'Sandbox'];
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return reply({ error: 'POST only' }, 405);
  const url = Deno.env.get('SUPABASE_URL')!;
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }
  });
  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return reply({ error: 'sign in first' }, 401);

  let jws = '';
  try { jws = String((await req.json()).jws || ''); } catch (_) { /* answered below */ }
  try {
    if (peek(jws).environment === 'Xcode') return reply({ status: 'test' });
    const tx = checkTransaction(verifyAppleJws(jws), { bundleId: BUNDLE_ID, userId: user.id, products: PRODUCTS, environments: ENVIRONMENTS });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data, error } = await admin.rpc('credit_purchase', { p_user: user.id, p_store: 'appstore', p_product: tx.productId, p_order: tx.transactionId });
    if (error) throw new Error(error.message);
    return reply({ status: 'credited', tokens: data ?? 0, productId: tx.productId });
  } catch (e) {
    console.warn('[apple-purchase]', user.id, e instanceof Error ? e.message : e);
    return reply({ error: e instanceof Error ? e.message : 'purchase check failed' }, 400);
  }
});
