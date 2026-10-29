const mimeTypes = {
  html: 'text/html; charset=utf-8', js: 'text/javascript; charset=utf-8',
  css: 'text/css; charset=utf-8', json: 'application/json; charset=utf-8',
  md: 'text/markdown; charset=utf-8',
  svg: 'image/svg+xml', png: 'image/png', jpg: 'image/jpeg', avif: 'image/avif',
  webp: 'image/webp', gif: 'image/gif', ico: 'image/x-icon',
  woff: 'font/woff', woff2: 'font/woff2', ttf: 'font/ttf', wasm: 'application/wasm',
};
const frontendPolicy = "default-src 'self' devtools: data:; style-src 'self' 'unsafe-inline' devtools:; " +
  "object-src 'none'; script-src 'self'; img-src 'self' data: blob:; frame-src * data:; " +
  "connect-src data: https://chromeuxreport.googleapis.com 'self' devtools:;";

export function allowCDPConnection(policy, url) {
  return policy.replace(/(^|;)(\s*connect-src\b[^;]*)/i, `$1$2 wss://${url.host}`);
}

export async function serveCDPFrontend(path, url, env) {
  const assetPath = /^\/frontend\/([a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)$/.exec(path)?.[1];
  const mime = assetPath && mimeTypes[assetPath.split('.').pop()];
  if (!mime || assetPath.split('/').some(part => !part || part.startsWith('.'))) {
    return new Response('Not found', { status: 404 });
  }
  try {
    // Only packaged files are served. No browser queries or credentials reach
    // the disk service, and there is no network fallback.
    const assetURL = new URL('http://devtools-frontend');
    assetURL.pathname = `/${assetPath}`;
    const upstream = await env.DEVTOOLS_FRONTEND.fetch(new Request(assetURL));
    if (!upstream.ok) {
      await upstream.body?.cancel();
      return new Response('DevTools frontend unavailable', { status: upstream.status === 404 ? 404 : 502 });
    }
    const headers = new Headers({
      'Content-Type': mime,
      'Cache-Control': 'no-cache',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    });
    headers.set('Content-Security-Policy', allowCDPConnection(frontendPolicy, url));
    const response = new Response(upstream.body, { headers });
    if (!headers.get('Content-Type').toLowerCase().includes('text/html')) return response;
    headers.set('Cache-Control', 'no-store');
    return new HTMLRewriter().on('meta', { element(element) {
      if (element.getAttribute('http-equiv')?.toLowerCase() !== 'content-security-policy') return;
      const policy = element.getAttribute('content');
      if (policy) element.setAttribute('content', allowCDPConnection(policy, url));
    } }).transform(new Response(response.body, { headers }));
  } catch {
    return new Response('DevTools frontend unavailable', { status: 502 });
  }
}
