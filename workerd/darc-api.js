const repositoryCheckoutPath = '/v1.24/repos/checkout';
const darcOrigins = new Set([
  'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic',
  'https://localhost:5194',
]);

function denied() {
  return new Response('Forbidden', {
    status: 403, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

export function darcAPIMethod(url) {
  if (url.pathname === repositoryCheckoutPath) return 'POST';
  if (url.pathname === '/v1.24/app-ports' || url.pathname === '/v1.24/ls' ||
      /^\/v1\.24\/(?:config|ps)\/[^/]+$/.test(url.pathname)) return 'GET';
  return null;
}

export function isDarcAPIRequest(request, url, origin) {
  const method = darcAPIMethod(url);
  return darcOrigins.has(origin) && method !== null &&
    (request.method === method || request.method === 'OPTIONS');
}

export function addDarcCors(headers, origin) {
  headers.set('Access-Control-Allow-Origin', origin);
  headers.append('Vary', 'Origin');
}

export function darcPreflight(request, url, origin) {
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
