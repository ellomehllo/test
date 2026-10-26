// Cloudflare Worker for vanarsathi.online: every request comes here first (run_worker_first) and is handed to the
// static assets; only Range requests are answered here, because Cloudflare's static asset hosting always returns
// the whole file and Safari on iPhone/iPad won't play video without 206 partial responses.
// Downloads (the Android app) come from the R2 bucket bound as DOWNLOADS: /download/sadhana.apk → object sadhana.apk.
const DOWNLOAD_TYPES = { apk: 'application/vnd.android.package-archive' };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname.startsWith('/download/') && env.DOWNLOADS) return download(request, env, url.pathname.slice(10));
    const range = request.headers.get('Range');
    if (!range) return withRanges(await env.ASSETS.fetch(request));
    const head = request.method === 'HEAD';
    const res = await env.ASSETS.fetch(new Request(request.url, { method: 'GET' }));
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (res.status !== 200 || !m || (m[1] === '' && m[2] === '')) return withRanges(res);
    // the asset response doesn't always say how big the file is, so read it (videos here are a few MB at most)
    const buf = await res.arrayBuffer(), size = buf.byteLength;
    let start, end;
    if (m[1] === '') { start = Math.max(0, size - Number(m[2])); end = size - 1; }      // "bytes=-500": the last 500
    else { start = Number(m[1]); end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1); }
    if (start > end || start >= size) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    const headers = new Headers(res.headers);
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    headers.set('Accept-Ranges', 'bytes');
    return new Response(head ? null : buf.slice(start, end + 1), { status: 206, headers });
  }
};

function withRanges(res) {
  const r = new Response(res.body, res);
  r.headers.set('Accept-Ranges', 'bytes');
  return r;
}

// a file from R2, with Range support (download managers resume) and a filename for the browser
async function download(request, env, key) {
  if (!/^[a-z0-9._-]+$/i.test(key) || (request.method !== 'GET' && request.method !== 'HEAD')) return new Response('Not found', { status: 404 });
  const obj = request.method === 'HEAD' ? await env.DOWNLOADS.head(key) : await env.DOWNLOADS.get(key, { range: request.headers, onlyIf: request.headers });
  if (!obj) return new Response('Not found', { status: 404 });
  const headers = new Headers();
  obj.writeHttpMetadata(headers);
  headers.set('ETag', obj.httpEtag);
  headers.set('Accept-Ranges', 'bytes');
  headers.set('Content-Type', DOWNLOAD_TYPES[key.split('.').pop()] || headers.get('Content-Type') || 'application/octet-stream');
  headers.set('Content-Disposition', `attachment; filename="${key}"`);
  headers.set('Cache-Control', 'public, max-age=300');
  if (request.method === 'HEAD' || !('body' in obj) || !obj.body) { headers.set('Content-Length', String(obj.size)); return new Response(null, { status: 200, headers }); }
  if (obj.range) {
    const start = obj.range.offset ?? 0, len = obj.range.length ?? obj.size - start;
    headers.set('Content-Range', `bytes ${start}-${start + len - 1}/${obj.size}`);
    headers.set('Content-Length', String(len));
    return new Response(obj.body, { status: 206, headers });
  }
  headers.set('Content-Length', String(obj.size));
  return new Response(obj.body, { status: 200, headers });
}
