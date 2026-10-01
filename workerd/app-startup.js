import { invalidateApplicationService } from './app-discovery.js';
import { startupResponse } from './startup-response.js';
import { readRuntimeStatus } from './runtime-status.js';

// Share an in-flight start between requests for any port of the same container.
const starts = new Map();
const startupResponses = new WeakSet();
const startupWindow = 120_000;
const startable = new Set(['uncreated', 'created', 'exited', 'stopped']);

function serviceKey(service) {
  return JSON.stringify([service.project, service.configFiles || '', service.service, Number(service.number) || 1]);
}

export function isApplicationStopped(service) {
  return startable.has(service.state);
}

export function applicationStart(service) {
  const key = service.id && starts.has(service.id) ? service.id : serviceKey(service);
  const entry = starts.get(key);
  if (entry && !entry.pending && entry.expires <= Date.now()) {
    starts.delete(key);
    return undefined;
  }
  return entry;
}

async function startError(response) {
  const body = await response.text();
  let detail;
  try {
    const result = JSON.parse(body);
    detail = typeof result.error === 'string' ? result.error : result.message;
  } catch {
    if (response.headers.get('content-type')?.startsWith('text/plain')) detail = body;
  }
  detail = typeof detail === 'string' ? detail.trim().slice(0, 2000) : '';
  return new Error(`Compose returned HTTP ${response.status}${detail ? `: ${detail}` : ' while starting this app.'}`);
}

export async function startApplication(service, env) {
  let entry = applicationStart(service);
  if (entry) return entry;
  // Creating a container may build an image. Restored tabs must not start
  // that work while the launcher is still bringing up the container runtime.
  if (!service.id) {
    const runtime = await readRuntimeStatus(env);
    if (runtime.phase !== 'healthy') return {
      pending: false, promise: Promise.resolve(),
      error: ['failed', 'stopped'].includes(runtime.phase) ? runtime.message : false,
      message: runtime.message,
    };
    // Docker may be ready before the guest router has claimed its socket.
    // Its health endpoint is independent of Docker and does no discovery.
    let routerReady = false;
    try {
      const response = await env.ROUTER.fetch(new Request('http://localhost/__xe_router_health', {
        signal: AbortSignal.timeout(1000),
      }));
      routerReady = response.ok;
      await response.body?.cancel();
    } catch {}
    if (!routerReady) return {
      pending: false, promise: Promise.resolve(), error: false,
      message: 'Starting application router…',
    };
  }
  // Another port may have started this service while status was being read.
  entry = applicationStart(service);
  if (entry) return entry;
  for (const [id, value] of starts) {
    if (!value.pending && value.expires <= Date.now()) starts.delete(id);
  }
  entry = { pending: true, error: false, expires: Infinity, promise: null };
  starts.set(service.id || serviceKey(service), entry);
  entry.promise = (async () => {
    try {
      const response = await env.COMPOSE.fetch(new Request(
        `http://compose/v1.24/start/${encodeURIComponent(service.project)}/container`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ...(service.id ? { container: service.id } : { service: service.service }),
            ...(service.configFiles ? { path: service.configFiles } : {}) }),
          signal: AbortSignal.timeout(service.id ? 60_000 : 600_000),
        }));
      if (!response.ok) throw await startError(response);
      await response.arrayBuffer();
    } catch (error) {
      entry.error = error?.name === 'TimeoutError' ? 'Starting this app timed out.'
        : error?.message || 'Could not start this app.';
      console.warn('Application start failed:', service.project, service.service, entry.error);
    } finally {
      entry.pending = false;
      entry.expires = Date.now() + (entry.error ? 10_000 : startupWindow);
      invalidateApplicationService(service, env);
    }
  })();
  return entry;
}

export function applicationReady(service) {
  starts.delete(service.id);
  starts.delete(serviceKey(service));
}

export function isApplicationStartupResponse(response) {
  return startupResponses.has(response);
}

export function applicationStarting(request, service, failed = false, startingMessage = 'Starting…') {
  const message = failed ? typeof failed === 'string' ? failed
    : 'Could not start this app. Try again or check its logs in Compose.' : startingMessage;
  const response = startupResponse(request, {
    name: service.service, message, failed: Boolean(failed),
    payload: { app: service.service, state: failed ? 'failed' : 'starting', message },
  });
  startupResponses.add(response);
  return response;
}
