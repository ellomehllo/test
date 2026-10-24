// Cloudflare Worker for vanarsathi.online: static files are served by Cloudflare directly; this script only runs
// for video files (see run_worker_first in wrangler.jsonc) to answer HTTP Range requests. Cloudflare's static
// asset hosting always returns the whole file, and Safari on iPhone/iPad won't play video without 206 responses.
export default {
  async fetch(request, env) {
    const range = request.headers.get('Range');
    const head = request.method === 'HEAD';
    const res = await env.ASSETS.fetch(new Request(request.url, { method: head ? 'HEAD' : 'GET' }));
    const size = Number(res.headers.get('Content-Length'));
    if (!range || res.status !== 200 || !size) return withRanges(res);
    const m = /^bytes=(\d*)-(\d*)$/.exec(range.trim());
    if (!m || (m[1] === '' && m[2] === '')) return withRanges(res);
    let start, end;
    if (m[1] === '') { start = Math.max(0, size - Number(m[2])); end = size - 1; }      // "bytes=-500": the last 500
    else { start = Number(m[1]); end = m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1); }
    if (start > end || start >= size) return new Response(null, { status: 416, headers: { 'Content-Range': `bytes */${size}` } });
    const headers = new Headers(res.headers);
    headers.set('Content-Range', `bytes ${start}-${end}/${size}`);
    headers.set('Content-Length', String(end - start + 1));
    headers.set('Accept-Ranges', 'bytes');
    return new Response(head ? null : res.body.pipeThrough(slice(start, end + 1)), { status: 206, headers });
  }
};

function withRanges(res) {
  const r = new Response(res.body, res);
  r.headers.set('Accept-Ranges', 'bytes');
  return r;
}

// passes through only bytes [from, to) of the stream
function slice(from, to) {
  let pos = 0;
  return new TransformStream({
    transform(chunk, ctl) {
      const s = pos, e = pos + chunk.byteLength;
      pos = e;
      if (e > from && s < to) ctl.enqueue(chunk.subarray(Math.max(0, from - s), Math.min(chunk.byteLength, to - s)));
      if (pos >= to) ctl.terminate();
    }
  });
}
