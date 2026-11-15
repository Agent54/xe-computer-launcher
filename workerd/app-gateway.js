import { readAppPorts } from './app-ports.js';
import { routeApplication } from './app-routing.js';
import { isApplicationStartupResponse } from './app-startup.js';
import { readRuntimeStatus, runtimeUnavailable, surfaceRuntimeFailure } from './runtime-status.js';
import { routingErrorResponse } from './startup-response.js';
import { isDarcAPIRequest, addDarcCors, darcPreflight } from './darc-api.js';
import { isCDPPath, handleCDP } from './cdp.js';

const applicationHost = /^(?:[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost|[a-z0-9][a-z0-9_-]*\.app\.localhost)$/;
const uiHost = 'compose-ui.localhost';

function denied(request, message = 'This request is not allowed on the application listener.', code = 'app_request_forbidden') {
  return routingErrorResponse(request, message, { status: 403, code });
}

const applicationGateway = {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (!['http:', 'https:'].includes(url.protocol) ||
        !applicationHost.test(url.hostname) || url.hostname === 'api.moby.localhost') {
      return denied(request, 'Unrecognized app host. Open the app from Compose to use its current local address.', 'invalid_app_host');
    }
    const ports = await readAppPorts(env);
    if (!ports || !ports.publicHttpReady) {
      return routingErrorResponse(request, 'Selected local app ports are unavailable. Check the port helper in Xe Launcher System Logs.', {
        code: 'app_listener_unavailable',
      });
    }
    const { http, https } = ports;
    const expectedPort = url.protocol === 'https:' ? https : http;
    if (url.port !== (expectedPort === (url.protocol === 'https:' ? 443 : 80) ? '' : String(expectedPort))) {
      return denied(request, 'This address uses an inactive app port. Open the app from Compose to use the selected listener.', 'invalid_app_port');
    }
    if (url.hostname === uiHost) {
      if (isCDPPath(url.pathname)) return handleCDP(request, env, ctx);
      const origin = request.headers.get('Origin');
      const darcAPIRequest = url.protocol === 'https:' && isDarcAPIRequest(request, url, origin);
      if ((origin && origin !== url.origin && !darcAPIRequest) ||
          (request.headers.get('Sec-Fetch-Site') === 'cross-site' && !darcAPIRequest)) return denied(request);
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
    const response = await routeApplication(request, env, ctx);
    return response.status >= 500 && !isApplicationStartupResponse(response)
      ? await surfaceRuntimeFailure(response, env, request) : response;
  },
};

export default {
  async fetch(request, env, ctx) {
    try {
      return await applicationGateway.fetch(request, env, ctx);
    } catch (error) {
      console.warn('Application route failed:', new URL(request.url).hostname, error);
      const runtime = await readRuntimeStatus(env);
      if (runtime.phase !== 'healthy') return await runtimeUnavailable(env, { request, runtime });
      return routingErrorResponse(request,
        `${error?.message || 'Could not route this app.'} Open Compose to check the service and its published ports, then try again.`);
    }
  },
};
