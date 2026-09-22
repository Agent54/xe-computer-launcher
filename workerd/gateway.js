import { routeApplication } from './app-routing.js';
import { runtimeUnavailable, surfaceRuntimeFailure } from './runtime-status.js';

// The gateway is the only public worker. Backends have no listener of their own.
const managementOrigin = 'http://127.0.0.1:8094';
const repositoryCheckoutPath = '/v1.24/repos/checkout';
const repositoryCheckoutOrigins = new Set([
  'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic',
  'https://localhost:5194',
]);

function denied(status = 403) {
  return new Response('Forbidden', {
    status, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

function isRepositoryCheckoutRequest(request, url, origin) {
  return url.pathname === repositoryCheckoutPath && repositoryCheckoutOrigins.has(origin) &&
    (request.method === 'POST' || request.method === 'OPTIONS');
}

function addRepositoryCheckoutCors(headers, origin) {
  headers.set('Access-Control-Allow-Origin', origin);
  headers.append('Vary', 'Origin');
}

function repositoryCheckoutPreflight(request, origin) {
  if (request.headers.get('Access-Control-Request-Method') !== 'POST') return denied();
  const requestedHeaders = (request.headers.get('Access-Control-Request-Headers') || '')
    .split(',').map(header => header.trim().toLowerCase()).filter(Boolean);
  if (requestedHeaders.some(header => header !== 'content-type')) return denied();
  const headers = new Headers({
    'Access-Control-Allow-Methods': 'POST',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '600',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Vary': 'Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network',
  });
  addRepositoryCheckoutCors(headers, origin);
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
      const repositoryCheckout = isRepositoryCheckoutRequest(request, url, origin);
      if ((origin && origin !== managementOrigin && !repositoryCheckout) ||
          (request.headers.get('Sec-Fetch-Site') === 'cross-site' && !repositoryCheckout)) {
        return denied();
      }
      if (repositoryCheckout && request.method === 'OPTIONS') {
        return repositoryCheckoutPreflight(request, origin);
      }
      const response = await env.MANAGEMENT.fetch(request);
      const headers = new Headers(response.headers);
      headers.set('X-Content-Type-Options', 'nosniff');
      headers.set('Referrer-Policy', 'no-referrer');
      headers.set('X-Frame-Options', 'DENY');
      if (repositoryCheckout) addRepositoryCheckoutCors(headers, origin);
      // The pinned Svelte build has an inline hydration script.
      headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
      return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
    }
    // App routing is local and hostname-scoped. Management is never exposed on
    // an app origin, including api.moby.localhost and arbitrary Host headers.
    if (url.protocol !== 'http:' || url.port !== '' ||
        !/^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost$/.test(url.hostname) ||
        url.hostname === 'api.moby.localhost') return denied();
    try {
      const response = await routeApplication(request, env);
      return response.status >= 500 ? await surfaceRuntimeFailure(response, env) : response;
    } catch {
      return await runtimeUnavailable(env);
    }
  },
};
