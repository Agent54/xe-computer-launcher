// Only the management socket can reach this worker. Backends have no listener of their own.
import { readAppPorts } from './app-ports.js';

const managementOrigin = 'http://127.0.0.1:8094';
const repositoryCheckoutPath = '/v1.24/repos/checkout';
const darcOrigins = new Set([
  'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic',
  'https://localhost:5194',
]);

function denied(status = 403) {
  return new Response('Forbidden', {
    status, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

function darcAPIMethod(url) {
  if (url.pathname === repositoryCheckoutPath) return 'POST';
  if (url.pathname === '/v1.24/ls' || /^\/v1\.24\/(?:config|ps)\/[^/]+$/.test(url.pathname)) return 'GET';
  return null;
}

function isDarcAPIRequest(request, url, origin) {
  const method = darcAPIMethod(url);
  return darcOrigins.has(origin) && method !== null &&
    (request.method === method || request.method === 'OPTIONS');
}

function addDarcCors(headers, origin) {
  headers.set('Access-Control-Allow-Origin', origin);
  headers.append('Vary', 'Origin');
}

function darcPreflight(request, url, origin) {
  const method = darcAPIMethod(url);
  if (request.headers.get('Access-Control-Request-Method') !== method) return denied();
  const requestedHeaders = (request.headers.get('Access-Control-Request-Headers') || '')
    .split(',').map(header => header.trim().toLowerCase()).filter(Boolean);
  if (requestedHeaders.some(header => header !== 'content-type') ||
      (requestedHeaders.includes('content-type') && method !== 'POST')) return denied();
  const headers = new Headers({
    'Access-Control-Allow-Methods': method,
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '600',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network',
  });
  addDarcCors(headers, origin);
  if (request.headers.get('Access-Control-Request-Private-Network') === 'true') {
    headers.set('Access-Control-Allow-Private-Network', 'true');
  }
  return new Response(null, { status: 204, headers });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // Do not accept a forwarded Host or a DNS-rebinding hostname for management.
    if (url.origin === managementOrigin) {
      const origin = request.headers.get('Origin');
      const darcAPIRequest = isDarcAPIRequest(request, url, origin);
      if ((origin && origin !== managementOrigin && !darcAPIRequest) ||
          (request.headers.get('Sec-Fetch-Site') === 'cross-site' && !darcAPIRequest)) {
        return denied();
      }
      // A browser opened on the private management UI would otherwise build
      // application links using :8094. Send navigations to the shared public
      // listener; keep the management API and readiness probe on this socket.
      if (request.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html') &&
          request.headers.get('Sec-Fetch-Mode') === 'navigate') {
        const { http, publicHttpReady } = await readAppPorts(env);
        if (publicHttpReady) {
          const publicURL = new URL(url);
          publicURL.hostname = 'compose-ui.localhost';
          publicURL.port = http === 80 ? '' : String(http);
          publicURL.pathname = '/';
          return new Response(null, { status: 307, headers: {
            Location: publicURL.href, 'Cache-Control': 'no-store',
          } });
        }
      }
      if (darcAPIRequest && request.method === 'OPTIONS') {
        return darcPreflight(request, url, origin);
      }
      const response = await env.MANAGEMENT.fetch(request);
      const headers = new Headers(response.headers);
      headers.set('X-Content-Type-Options', 'nosniff');
      headers.set('Referrer-Policy', 'no-referrer');
      headers.set('X-Frame-Options', 'DENY');
      if (darcAPIRequest) addDarcCors(headers, origin);
      // The pinned Svelte build has an inline hydration script.
      headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
      return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
    }
    return denied();
  },
};
