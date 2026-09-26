import { readAppPorts } from './app-ports.js';
import { routeApplication } from './app-routing.js';
import { runtimeUnavailable, surfaceRuntimeFailure } from './runtime-status.js';
import { isDarcAPIRequest, addDarcCors, darcPreflight } from './darc-api.js';

const applicationHost = /^(?:[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost|[a-z0-9][a-z0-9_-]*\.app\.localhost)$/;
const uiHost = 'compose-ui.localhost';

function denied() {
  return new Response('Forbidden', { status: 403, headers: { 'Cache-Control': 'no-store' } });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (!['http:', 'https:'].includes(url.protocol) ||
        !applicationHost.test(url.hostname) || url.hostname === 'api.moby.localhost') return denied();
    const ports = await readAppPorts(env);
    if (!ports || !ports.publicHttpReady) {
      return new Response('Selected local app ports are unavailable', { status: 503, headers: { 'Cache-Control': 'no-store' } });
    }
    const { http, https } = ports;
    const expectedPort = url.protocol === 'https:' ? https : http;
    if (url.port !== (expectedPort === (url.protocol === 'https:' ? 443 : 80) ? '' : String(expectedPort))) {
      return denied();
    }
    if (url.hostname === uiHost) {
      const origin = request.headers.get('Origin');
      const darcAPIRequest = url.protocol === 'https:' && isDarcAPIRequest(request, url, origin);
      if ((origin && origin !== url.origin && !darcAPIRequest) ||
          (request.headers.get('Sec-Fetch-Site') === 'cross-site' && !darcAPIRequest)) return denied();
      if (darcAPIRequest && request.method === 'OPTIONS') return darcPreflight(request, url, origin);
      const forwardedHeaders = new Headers(request.headers);
      if (darcAPIRequest) {
        // The public gateway has already checked the signed app and API route.
        // The private management worker still rejects browser cross-site headers.
        forwardedHeaders.delete('Origin');
        forwardedHeaders.delete('Sec-Fetch-Site');
      }
      const response = await env.MANAGEMENT.fetch(new Request(request, { headers: forwardedHeaders }));
      const headers = new Headers(response.headers);
      headers.set('X-Content-Type-Options', 'nosniff');
      headers.set('Referrer-Policy', 'no-referrer');
      headers.set('X-Frame-Options', 'DENY');
      if (darcAPIRequest) addDarcCors(headers, origin);
      headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
      return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
    }
    try {
      const response = await routeApplication(request, env, ctx);
      return response.status >= 500 ? await surfaceRuntimeFailure(response, env) : response;
    } catch {
      return await runtimeUnavailable(env);
    }
  },
};
