// Only the management socket can reach this worker. Backends have no listener of their own.
import { readAppPorts } from './app-ports.js';
import { isDarcAPIRequest, addDarcCors, darcPreflight } from './darc-api.js';

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
        const ports = await readAppPorts(env);
        if (!ports) {
          return new Response('Xe Launcher app port configuration is unavailable.', {
            status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
          });
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
        return new Response(`Xe Launcher has not activated the selected HTTP port ${http}. Check the port helper in System Logs.`, {
          status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
        });
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
