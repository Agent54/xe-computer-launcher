import { readRuntimeStatus, runtimeUnavailable, surfaceRuntimeFailure } from './runtime-status.js';

const mimeTypes = {
  html: 'text/html; charset=utf-8', js: 'text/javascript; charset=utf-8',
  css: 'text/css; charset=utf-8', json: 'application/json; charset=utf-8',
  svg: 'image/svg+xml', png: 'image/png', ico: 'image/x-icon',
  woff: 'font/woff', woff2: 'font/woff2', txt: 'text/plain; charset=utf-8',
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/v1.24/runtime-status' && request.method === 'GET') {
      return Response.json(await readRuntimeStatus(env), { headers: { 'Cache-Control': 'no-store' } });
    }
    if (/^\/v1\.24\//.test(url.pathname)) {
      const headers = new Headers(request.headers);
      // Browser credentials do not belong to the local Compose API.
      for (const name of ['cookie', 'authorization', 'host', 'forwarded', 'x-forwarded-host', 'x-forwarded-for']) headers.delete(name);
      try {
        const response = await env.COMPOSE.fetch(new Request(request, { headers }));
        const resultHeaders = new Headers(response.headers);
        resultHeaders.set('Cache-Control', 'no-store');
        resultHeaders.delete('set-cookie');
        resultHeaders.delete('access-control-allow-origin');
        if (response.status >= 500) return await surfaceRuntimeFailure(response, env);
        // Passing the body through preserves SSE and cancellation; never .text().
        return new Response(response.body, { status: response.status, statusText: response.statusText, headers: resultHeaders });
      } catch { return await runtimeUnavailable(env); }
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    let path;
    try { path = decodeURIComponent(url.pathname); } catch { return new Response('Invalid path', { status: 400 }); }
    if (path.includes('\\') || path.split('/').some(part => part.startsWith('.')) || path.includes('\0')) {
      return new Response('Not found', { status: 404 });
    }
    if (path === '/') path = '/index.html';
    // This release has one page and uses hash navigation. Do not return HTML
    // for missing JS, API routes, or directories (disk serves directory lists).
    const extension = path.split('.').pop();
    if (!mimeTypes[extension]) return new Response('Not found', { status: 404 });
    const assetUrl = new URL('http://assets');
    assetUrl.pathname = path;
    const response = await env.ASSETS.fetch(new Request(assetUrl, { method: request.method }));
    if (!response.ok) return new Response('Not found', { status: 404 });
    const headers = new Headers(response.headers);
    headers.set('Content-Type', mimeTypes[extension]);
    headers.set('Cache-Control', path.startsWith('/_app/immutable/') ? 'public, max-age=31536000, immutable' : 'no-cache');
    return new Response(response.body, { status: response.status, headers });
  },
};
