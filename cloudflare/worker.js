// Cloudflare Worker for vanarsathi.online: every request comes here first (run_worker_first) and is handed to the
// static assets; only Range requests are answered here, because Cloudflare's static asset hosting always returns
// the whole file and Safari on iPhone/iPad won't play video without 206 partial responses.
export default {
  async fetch(request, env) {
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
