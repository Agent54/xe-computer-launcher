import { routeApplication } from './app-routing.js';

// The gateway is the only public worker. Backends have no listener of their own.
const managementOrigin = 'http://127.0.0.1:8094';

function denied(status = 403) {
  return new Response('Forbidden', {
    status, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Do not accept a forwarded Host or a DNS-rebinding hostname for management.
    if (url.origin === managementOrigin) {
      const origin = request.headers.get('Origin');
      if ((origin && origin !== managementOrigin) || request.headers.get('Sec-Fetch-Site') === 'cross-site') {
        return denied();
      }
      const response = await env.MANAGEMENT.fetch(request);
      const headers = new Headers(response.headers);
      headers.set('X-Content-Type-Options', 'nosniff');
      headers.set('Referrer-Policy', 'no-referrer');
      headers.set('X-Frame-Options', 'DENY');
      // The pinned Svelte build has an inline hydration script.
      headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
      return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
    }
    // App routing is local and hostname-scoped. Management is never exposed on
    // an app origin, including api.moby.localhost and arbitrary Host headers.
    if (url.protocol !== 'http:' || url.port !== '5196' ||
        !/^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost$/.test(url.hostname) ||
        url.hostname === 'api.moby.localhost') return denied();
    try {
      return await routeApplication(request, env);
    } catch {
      return new Response('Application routing unavailable. Retry when Compose and the VM are ready.', {
        status: 503, headers: { 'Retry-After': '2', 'Cache-Control': 'no-store' },
      });
    }
  },
};
