// Checks a StoreKit 2 signed transaction (JWS) the way Apple documents it: the certificate chain in the header must end
// at Apple Root CA - G3, the leaf and intermediate must carry Apple's App Store receipt-signing extensions, and the
// ES256 signature must match the leaf key. Plain node:crypto, so it runs in Supabase Edge Functions and in Node tests.
import { X509Certificate, createHash, verify } from 'node:crypto';
import { Buffer } from 'node:buffer';

// SHA-256 of https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (valid 2014-04-30 … 2039-04-30)
export const APPLE_ROOT_G3 = '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79';
// DER bodies of 1.2.840.113635.100.6.11.1 (receipt signing, leaf) and 1.2.840.113635.100.6.2.1 (WWDR, intermediate)
const LEAF_OID = Buffer.from('2a864886f76364060b01', 'hex');
const MID_OID = Buffer.from('2a864886f76364060201', 'hex');

const part = (s: string) => JSON.parse(Buffer.from(s, 'base64url').toString('utf8'));
// SHA-256 of a certificate's DER bytes as AA:BB:…, worked out here: Deno's X509Certificate.fingerprint256 isn't
// formatted like Node's, so comparing against it rejected every genuine purchase
const sha256Fingerprint = (der: Buffer) => createHash('sha256').update(der).digest('hex').toUpperCase().match(/../g)!.join(':');
const norm = (f: string) => f.replace(/[^0-9a-f]/gi, '').toUpperCase();

/** The payload without any checks: only used to read the environment before deciding how to treat it. */
export function peek(jws: string): Record<string, unknown> {
  const p = String(jws || '').split('.');
  if (p.length !== 3) throw new Error('not a signed transaction');
  return part(p[1]);
}

/** Verifies the signature and certificate chain; returns the decoded transaction. Throws if anything is off. */
export function verifyAppleJws(jws: string, rootFingerprints: string[] = [APPLE_ROOT_G3]): Record<string, any> {
  const [h, p, sig] = String(jws || '').split('.');
  if (!h || !p || !sig) throw new Error('not a signed transaction');
  const header = part(h);
  if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) throw new Error('unexpected header');
  const ders = header.x5c.map((c: string) => Buffer.from(c, 'base64'));
  const [leaf, mid, root] = ders.map((d: Buffer) => new X509Certificate(d));
  if (!rootFingerprints.map(norm).includes(norm(sha256Fingerprint(ders[2])))) throw new Error('not signed by Apple');
  if (!mid.verify(root.publicKey) || !leaf.verify(mid.publicKey)) throw new Error('broken certificate chain');
  if (!ders[0].includes(LEAF_OID) || !ders[1].includes(MID_OID)) throw new Error('not an App Store signing certificate');
  const payload = part(p);
  const at = new Date(typeof payload.signedDate === 'number' ? payload.signedDate : Date.now());
  for (const c of [leaf, mid, root]) {
    if (at < new Date(c.validFrom) || at > new Date(c.validTo)) throw new Error('certificate not valid at signing time');
  }
  const ok = verify('sha256', Buffer.from(`${h}.${p}`), { key: leaf.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url'));
  if (!ok) throw new Error('bad signature');
  return payload;
}

/** The transaction must be one of our consumables, for this app and this account, and not refunded. */
export function checkTransaction(tx: Record<string, any>, o: { bundleId: string; userId: string; products: string[]; environments: string[] }) {
  if (tx.bundleId !== o.bundleId) throw new Error('another app');
  if (!o.products.includes(tx.productId)) throw new Error('unknown product');
  if (tx.type !== 'Consumable') throw new Error('not a consumable');
  if (!tx.appAccountToken || String(tx.appAccountToken).toLowerCase() !== o.userId.toLowerCase()) throw new Error('another account');
  if (tx.revocationDate) throw new Error('refunded');
  if (!o.environments.includes(tx.environment)) throw new Error(`environment ${tx.environment} not accepted`);
  return { productId: String(tx.productId), transactionId: String(tx.transactionId) };
}
