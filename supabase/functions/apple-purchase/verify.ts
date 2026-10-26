// Checks a StoreKit 2 signed transaction (JWS) the way Apple documents it: the certificate chain in the header must end
// at Apple Root CA - G3, each certificate must be signed by the next, the leaf and intermediate must carry Apple's App
// Store receipt-signing extensions, and the ES256 signature must match the leaf key.
// Only Web Crypto and a small DER reader: Supabase runs Deno, whose node:crypto lacks X509Certificate.verify (and
// formats fingerprints differently), so nothing here depends on it. Runs the same in Deno and in Node 20+ tests.

// SHA-256 of https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (valid 2014-04-30 … 2039-04-30)
export const APPLE_ROOT_G3 = '63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79';
// DER bodies of 1.2.840.113635.100.6.11.1 (receipt signing, leaf) and 1.2.840.113635.100.6.2.1 (WWDR, intermediate)
const LEAF_OID = hex('2a864886f76364060b01');
const MID_OID = hex('2a864886f76364060201');
// signature algorithms (1.2.840.10045.4.3.2 / .3) and curves (prime256v1 / secp384r1)
const ECDSA_SHA256 = '2a8648ce3d040302', ECDSA_SHA384 = '2a8648ce3d040303';
const P256 = '2a8648ce3d030107', P384 = '2b81040022';

function hex(s: string): Uint8Array { return new Uint8Array(s.match(/../g)!.map(b => parseInt(b, 16))); }
const toHex = (b: Uint8Array) => [...b].map(x => x.toString(16).padStart(2, '0')).join('');
const b64 = (s: string) => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const b64url = (s: string) => b64(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '='));
const part = (s: string) => JSON.parse(new TextDecoder().decode(b64url(s)));
const norm = (f: string) => f.replace(/[^0-9a-f]/gi, '').toUpperCase();
const contains = (hay: Uint8Array, needle: Uint8Array) => {
  outer: for (let i = 0; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
};

// ── a minimal DER reader: enough to take an X.509 certificate apart
type Node = { tag: number; start: number; body: number; end: number };
function read(d: Uint8Array, at: number): Node {
  const tag = d[at];
  let len = d[at + 1], body = at + 2;
  if (len & 0x80) { const n = len & 0x7f; len = 0; for (let i = 0; i < n; i++) len = len * 256 + d[at + 2 + i]; body += n; }
  if (body + len > d.length) throw new Error('malformed certificate');
  return { tag, start: at, body, end: body + len };
}
function children(d: Uint8Array, n: Node): Node[] {
  const out: Node[] = [];
  for (let at = n.body; at < n.end;) { const c = read(d, at); out.push(c); at = c.end; }
  return out;
}

type Cert = { der: Uint8Array; tbs: Uint8Array; sigAlg: string; sig: Uint8Array; spki: Uint8Array; curve: string; notBefore: Date; notAfter: Date };
function parseTime(d: Uint8Array, n: Node): Date {
  const s = new TextDecoder().decode(d.subarray(n.body, n.end));   // UTCTime YYMMDDhhmmssZ or GeneralizedTime YYYYMMDDhhmmssZ
  const full = n.tag === 0x17 ? (Number(s.slice(0, 2)) < 50 ? '20' : '19') + s : s;
  return new Date(Date.UTC(+full.slice(0, 4), +full.slice(4, 6) - 1, +full.slice(6, 8), +full.slice(8, 10), +full.slice(10, 12), +full.slice(12, 14)));
}
function parseCert(der: Uint8Array): Cert {
  const [tbsN, algN, sigN] = children(der, read(der, 0));
  const tbsF = children(der, tbsN);
  const i = tbsF[0].tag === 0xa0 ? 1 : 0;                        // optional [0] version
  const validity = children(der, tbsF[i + 3]);
  const spkiN = tbsF[i + 5];
  const spkiAlg = children(der, children(der, spkiN)[0]);
  const algOid = children(der, algN)[0];
  return {
    der,
    tbs: der.subarray(tbsN.start, tbsN.end),
    sigAlg: toHex(der.subarray(algOid.body, algOid.end)),
    sig: der.subarray(sigN.body + 1, sigN.end),                   // BIT STRING: skip the unused-bits byte
    spki: der.subarray(spkiN.start, spkiN.end),
    curve: spkiAlg[1] ? toHex(der.subarray(spkiAlg[1].body, spkiAlg[1].end)) : '',
    notBefore: parseTime(der, validity[0]),
    notAfter: parseTime(der, validity[1])
  };
}

// a DER ECDSA signature (SEQUENCE of two INTEGERs) → the fixed-size r‖s form Web Crypto expects
function derToRaw(sig: Uint8Array, size: number): Uint8Array {
  const [r, s] = children(sig, read(sig, 0)).map(n => sig.subarray(n.body, n.end));
  const out = new Uint8Array(size * 2);
  const put = (x: Uint8Array, off: number) => { const t = x.subarray(Math.max(0, x.length - size)); out.set(t, off + size - t.length); };
  put(r, 0); put(s, size);
  return out;
}
const curveOf = (oid: string) => (oid === P256 ? { name: 'P-256', size: 32 } : oid === P384 ? { name: 'P-384', size: 48 } : null);
async function ecKey(c: Cert) {
  const curve = curveOf(c.curve);
  if (!curve) throw new Error('unexpected key type');
  return { curve, key: await crypto.subtle.importKey('spki', c.spki, { name: 'ECDSA', namedCurve: curve.name }, false, ['verify']) };
}
/** Is `child` signed by `issuer`? */
export async function signedBy(child: Cert, issuer: Cert): Promise<boolean> {
  const hash = child.sigAlg === ECDSA_SHA256 ? 'SHA-256' : child.sigAlg === ECDSA_SHA384 ? 'SHA-384' : null;
  if (!hash) return false;
  const { curve, key } = await ecKey(issuer);
  return crypto.subtle.verify({ name: 'ECDSA', hash }, key, derToRaw(child.sig, curve.size), child.tbs);
}
export { parseCert };

/** The payload without any checks: only used to read the environment before deciding how to treat it. */
export function peek(jws: string): Record<string, unknown> {
  const p = String(jws || '').split('.');
  if (p.length !== 3) throw new Error('not a signed transaction');
  return part(p[1]);
}

/** Verifies the signature and certificate chain; returns the decoded transaction. Throws if anything is off. */
export async function verifyAppleJws(jws: string, rootFingerprints: string[] = [APPLE_ROOT_G3]): Promise<Record<string, any>> {
  const [h, p, sig] = String(jws || '').split('.');
  if (!h || !p || !sig) throw new Error('not a signed transaction');
  const header = part(h);
  if (header.alg !== 'ES256' || !Array.isArray(header.x5c) || header.x5c.length !== 3) throw new Error('unexpected header');
  const ders = header.x5c.map((c: string) => b64(c));
  const rootFp = toHex(new Uint8Array(await crypto.subtle.digest('SHA-256', ders[2])));
  if (!rootFingerprints.map(norm).includes(norm(rootFp))) throw new Error('not signed by Apple');
  const [leaf, mid, root] = ders.map(parseCert);
  if (!(await signedBy(mid, root)) || !(await signedBy(leaf, mid))) throw new Error('broken certificate chain');
  if (!contains(leaf.der, LEAF_OID) || !contains(mid.der, MID_OID)) throw new Error('not an App Store signing certificate');
  const payload = part(p);
  const at = new Date(typeof payload.signedDate === 'number' ? payload.signedDate : Date.now());
  for (const c of [leaf, mid, root]) {
    if (at < c.notBefore || at > c.notAfter) throw new Error('certificate not valid at signing time');
  }
  const { key } = await ecKey(leaf);
  const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, b64url(sig), new TextEncoder().encode(`${h}.${p}`));
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
