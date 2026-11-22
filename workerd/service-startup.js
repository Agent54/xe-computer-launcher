import { readRuntimeStatus } from './runtime-status.js';

const startable = new Set(['uncreated', 'created', 'exited', 'stopped']);
const startupWindow = 120_000;

function serviceKey(service) {
  return JSON.stringify([service.project, service.configFiles || '', service.service, Number(service.number) || 1]);
}

function validService(service) {
  return service && ['project', 'service'].every(key => typeof service[key] === 'string' && service[key].trim()) &&
    (!service.configFiles || typeof service.configFiles === 'string') && (!service.id || typeof service.id === 'string');
}

function status(entry) {
  return entry ? { pending: entry.pending, error: entry.error, message: entry.message } : null;
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

// Shared by configured startup, HTTP requests and native TLS requests. Gateway
// workers hold no independent container-start state.
export class ServiceStartupCoordinator {
  constructor() {
    this.starts = new Map();
    this.bootId = null;
    this.controller = new AbortController();
    this.queue = null;
    this.completedBoot = null;
    this.stateWrites = Promise.resolve();
  }

  observeRuntime(runtime) {
    const changed = runtime.bootId && runtime.bootId !== this.bootId;
    const paused = ['starting', 'restarting', 'diagnosing', 'failed', 'stopped'].includes(runtime.phase);
    if (changed || paused) {
      this.controller.abort();
      this.starts.clear();
      if (changed) {
        this.bootId = runtime.bootId;
        this.completedBoot = null;
      }
    }
    if (!paused && this.controller.signal.aborted) this.controller = new AbortController();
    return !paused;
  }

  lookup(service) {
    const entry = (service.id && this.starts.get(service.id)) || this.starts.get(serviceKey(service));
    if (entry && !entry.pending && entry.expires <= Date.now()) {
      this.forget(entry);
      return undefined;
    }
    return entry;
  }

  forget(entry) {
    for (const [key, value] of this.starts) if (value === entry) this.starts.delete(key);
  }

  async start(service, env, { requireRouter = true, expectedGeneration = null } = {}) {
    const runtime = await readRuntimeStatus(env);
    const active = this.observeRuntime(runtime);
    if (!active || (expectedGeneration && expectedGeneration !== this.controller) ||
        (!service.id && runtime.phase !== 'healthy')) return {
      pending: false, promise: Promise.resolve(),
      error: ['failed', 'stopped'].includes(runtime.phase) ? runtime.message : false,
      message: runtime.message,
    };
    let entry = this.lookup(service);
    if (entry) return entry;
    const generation = this.controller;
    if (!service.id && requireRouter) {
      const ready = await this.probe(env.ROUTER, '/__xe_router_health');
      if (!ready) return { pending: false, promise: Promise.resolve(), error: false, message: 'Starting application router…' };
    }
    if (generation.signal.aborted) return { pending: false, promise: Promise.resolve(), error: false, message: 'Container runtime is restarting…' };
    entry = this.lookup(service);
    if (entry) return entry;
    for (const value of this.starts.values()) {
      if (!value.pending && value.expires <= Date.now()) this.forget(value);
    }
    entry = { pending: true, error: false, expires: Infinity, promise: null };
    this.starts.set(serviceKey(service), entry);
    if (service.id) this.starts.set(service.id, entry);
    entry.promise = (async () => {
      try {
        const response = await env.COMPOSE.fetch(new Request(
          `http://compose/v1.24/start/${encodeURIComponent(service.project)}/container`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ...(service.id ? { container: service.id } : { service: service.service }),
              ...(service.configFiles ? { path: service.configFiles } : {}) }),
            signal: AbortSignal.any([generation.signal, AbortSignal.timeout(service.id ? 60_000 : 600_000)]),
          }));
        if (!response.ok) throw await startError(response);
        await response.arrayBuffer();
      } catch (error) {
        entry.error = generation.signal.aborted ? 'Container startup was cancelled.'
          : error?.name === 'TimeoutError' ? 'Starting this app timed out.'
          : error?.message || 'Could not start this app.';
        console.warn('Application start failed:', service.project, service.service, entry.error);
      } finally {
        entry.pending = false;
        entry.expires = Date.now() + (entry.error ? 10_000 : startupWindow);
      }
    })();
    return entry;
  }

  async probe(binding, path) {
    try {
      const response = await binding.fetch(new Request(`http://localhost${path}`, { signal: AbortSignal.timeout(1000) }));
      const ready = response.ok;
      await response.body?.cancel();
      return ready;
    } catch { return false; }
  }

  async reconcile(env) {
    const runtime = await readRuntimeStatus(env);
    if (!this.observeRuntime(runtime) || runtime.phase !== 'healthy' || !runtime.bootId ||
        this.completedBoot === runtime.bootId || this.queue) return;
    const generation = this.controller;
    const bootId = runtime.bootId;
    const queue = this.runQueue(env, bootId, generation).catch(error => {
      if (!generation.signal.aborted) console.warn('Configured service startup failed:', error.message);
    }).finally(() => { if (this.queue === queue) this.queue = null; });
    this.queue = queue;
    await queue;
  }

  async runQueue(env, bootId, generation) {
    const response = await env.RUNTIME_STATUS.fetch('http://status/startup-services.json');
    if (!response.ok && response.status !== 404) throw new Error('Startup configuration is unavailable.');
    const services = response.status === 404 ? [] : await response.json();
    if (!Array.isArray(services) || !services.every(service => validService(service) &&
        typeof service.path === 'string' && service.path.trim())) {
      console.warn('Ignoring invalid compose_startup_services; expected project, service and path for every entry.');
      this.completedBoot = bootId;
      return;
    }
    if (!services.length) { this.completedBoot = bootId; return; }
    await this.stateWrites.catch(() => {});
    const saved = await env.STARTUP_STATE.fetch('http://startup-state/boot.json');
    // Refuse a corrupt/unavailable checkpoint rather than repeat starts.
    if (saved.status !== 404 && !saved.ok) throw new Error('Startup checkpoint is unavailable.');
    const previous = saved.status === 404 ? null : await saved.json();
    if (previous && (!Array.isArray(previous.attempted) || typeof previous.bootId !== 'string')) {
      throw new Error('Invalid startup checkpoint.');
    }
    const attempted = new Set(previous?.bootId === bootId ? previous.attempted : []);
    const requests = [...new Map(services.map(service => [JSON.stringify([service.project, service.service, service.path]), service]))];
    if (requests.every(([key]) => attempted.has(key))) { this.completedBoot = bootId; return; }
    const [docker, compose] = await Promise.all([this.probe(env.DOCKER, '/_ping'), this.probe(env.COMPOSE, '/_ping')]);
    if (!docker || !compose || generation.signal.aborted) return;
    for (const [key, requested] of requests) {
      if (generation.signal.aborted) return;
      const runtime = await readRuntimeStatus(env);
      if (!this.observeRuntime(runtime) || runtime.phase !== 'healthy' || runtime.bootId !== bootId) return;
      if (attempted.has(key)) continue;
      // Save before starting: a workerd restart during a build resumes the
      // remaining entries without replaying the same boot's work.
      attempted.add(key);
      const checkpoint = JSON.stringify({ bootId, attempted: [...attempted] });
      this.stateWrites = this.stateWrites.catch(() => {}).then(async () => {
        if (generation.signal.aborted) return;
        const saved = await env.STARTUP_STATE.fetch('http://startup-state/boot.json', { method: 'PUT', body: checkpoint });
        if (!saved.ok) throw new Error('Could not save startup checkpoint.');
        await saved.body?.cancel();
      });
      await this.stateWrites;
      if (generation.signal.aborted) return;
      try {
        // Resolve relative paths/symlinks into discovery's labelled config
        // files, so configured and request-driven starts share an identity.
        const url = new URL(`http://compose/v1.24/ps/${encodeURIComponent(requested.project)}`);
        url.searchParams.set('all', 'true');
        url.searchParams.set('path', requested.path);
        const response = await env.COMPOSE.fetch(new Request(url, {
          signal: AbortSignal.any([generation.signal, AbortSignal.timeout(10_000)]),
        }));
        if (!response.ok) throw await startError(response);
        const rows = await response.json();
        const row = rows.find(row => row.Service === requested.service &&
          row.Labels?.['com.docker.compose.oneoff']?.toLowerCase() !== 'true' &&
          (Number(row.Labels?.['com.docker.compose.container-number']) || Number(/[-_](\d+)$/.exec(row.Name || '')?.[1]) || 1) === 1);
        if (!row) throw new Error('Requested Compose service is unavailable.');
        if (row.State === 'running') continue;
        if (!startable.has(row.State)) throw new Error(`Requested service is ${row.State}.`);
        const service = { project: requested.project, service: requested.service, number: 1, id: row.ID,
          configFiles: row.Labels?.['com.docker.compose.project.config_files'] || requested.path };
        if (generation.signal.aborted) return;
        const entry = await this.start(service, env, { requireRouter: false, expectedGeneration: generation });
        await entry.promise;
        if (entry.error) throw new Error(entry.error);
        if (generation.signal.aborted) return;
        console.log('Started requested startup service', requested.project, requested.service);
      } catch (error) {
        if (generation.signal.aborted) return;
        console.warn('Could not start requested service:', requested.project, requested.service, error.message);
      }
    }
    if (!generation.signal.aborted) this.completedBoot = bootId;
  }

  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (path === '/reconcile' && request.method === 'GET') {
      ctx.waitUntil(this.reconcile(env));
      return new Response(null, { status: 202 });
    }
    if (request.method !== 'POST' || !['/start', '/status', '/wait', '/ready'].includes(path)) {
      return new Response('Not found', { status: 404 });
    }
    let service;
    try { service = await request.json(); } catch { return new Response('Invalid service', { status: 400 }); }
    if (!validService(service)) return new Response('Invalid service', { status: 400 });
    if (path !== '/start') this.observeRuntime(await readRuntimeStatus(env));
    const entry = path === '/start' ? await this.start(service, env) : this.lookup(service);
    if (path === '/ready') {
      if (entry && !entry.pending) this.forget(entry);
      return new Response(null, { status: 204 });
    }
    if (entry?.pending) {
      ctx.waitUntil(entry.promise);
      if (path === '/wait') await entry.promise;
    }
    return Response.json(status(entry));
  }
}

const coordinator = new ServiceStartupCoordinator();
export default { fetch: (request, env, ctx) => coordinator.fetch(request, env, ctx) };
