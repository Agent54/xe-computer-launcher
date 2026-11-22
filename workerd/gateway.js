// Only the management socket can reach this worker. Backends have no listener of their own.
import { readAppPorts } from './app-ports.js';
import { isDarcAPIRequest, addDarcCors, darcPreflight } from './darc-api.js';
import { routingErrorResponse } from './startup-response.js';

const managementOrigin = 'http://127.0.0.1:8094';

function failure(request, message, status = 503) {
  return routingErrorResponse(request, message, { status, source: 'Management gateway', code: 'management_unavailable' });
}

function denied(request) {
  return routingErrorResponse(request, 'This request is not allowed on the management listener.', {
    status: 403, source: 'Management gateway', code: 'management_request_forbidden',
  });
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
        return denied(request);
      }
      // A browser opened on the private management UI would otherwise build
      // application links using :8094. Send navigations to the shared public
      // listener; keep the management API and readiness probe on this socket.
      if (request.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html') &&
          request.headers.get('Sec-Fetch-Mode') === 'navigate') {
        const ports = await readAppPorts(env);
        if (!ports) {
          return failure(request, 'Xe Launcher app port configuration is unavailable.');
        }
        const { http, publicHttpReady } = ports;
        if (publicHttpReady) {
          const publicURL = new URL(url);
          publicURL.hostname = 'compose-ui.localhost';
          publicURL.port = http === 80 ? '' : String(http);
          publicURL.pathname = '/';
          return new Response(null, { status: 307, headers: {
            Location: publicURL.href, 'Cache-Control': 'no-store',
          } });
        }
        return failure(request, `Xe Launcher has not activated the selected HTTP port ${http}. Check the port helper in System Logs.`);
      }
      if (darcAPIRequest && request.method === 'OPTIONS') {
        return darcPreflight(request, url, origin);
      }
      let response;
      try { response = await env.MANAGEMENT.fetch(request); }
      catch (error) {
        console.warn('Management gateway failed:', error);
        return failure(request, 'Could not connect to Compose. Try again or check Xe Launcher System Logs.');
      }
      const headers = new Headers(response.headers);
      headers.set('X-Content-Type-Options', 'nosniff');
      headers.set('Referrer-Policy', 'no-referrer');
      headers.set('X-Frame-Options', 'DENY');
      if (darcAPIRequest) addDarcCors(headers, origin);
      // The pinned Svelte build has an inline hydration script.
      headers.set('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'");
      return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
    }
    return denied(request);
  },
};
