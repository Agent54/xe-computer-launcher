import assert from 'node:assert/strict';
import { ServiceStartupCoordinator } from '../service-startup.js';
import { applicationReady, startApplication } from '../app-startup.js';

const web = { project: 'demo', service: 'web', path: 'demo/compose.yaml' };
const worker = { ...web, service: 'worker' };

function fixture() {
  let coordinator = new ServiceStartupCoordinator();
  const runtime = { phase: 'healthy', bootId: 'boot-1', message: 'ready' };
  let services: unknown = [];
  let saved: string | undefined;
  let writable = true;
  let docker = true;
  let compose = true;
  let slow = false;
  let aborted = 0;
  let probes = 0;
  let stateReads = 0;
  const starts: { service?: string; container?: string; path: string }[] = [];
  const releases: (() => void)[] = [];
  const background: Promise<unknown>[] = [];
  const ctx = { waitUntil(promise: Promise<unknown>) { background.push(promise); } };
  const env = {
    RUNTIME_STATUS: { fetch: async (url: string) => Response.json(url.endsWith('startup-services.json') ? services : runtime) },
    STARTUP_STATE: { fetch: async (_url: string, init?: RequestInit) => {
      if (init?.method === 'PUT') {
        if (!writable) return new Response(null, { status: 500 });
        saved = String(init.body);
        return new Response(null, { status: 204 });
      }
      stateReads++;
      return saved ? new Response(saved) : new Response(null, { status: 404 });
    } },
    DOCKER: { fetch: async () => { probes++; return new Response(null, { status: docker ? 200 : 503 }); } },
    ROUTER: { fetch: async () => new Response(null, { status: 200 }) },
    COMPOSE: { fetch: async (request: Request) => {
      const url = new URL(request.url);
      if (url.pathname === '/_ping') {
        probes++;
        return new Response(null, { status: compose ? 200 : 503 });
      }
      if (url.pathname === '/v1.24/ps/demo') {
        assert.equal(url.searchParams.get('all'), 'true');
        assert.equal(url.searchParams.get('path'), web.path);
        return Response.json([web, worker].map(service => ({
          Service: service.service, Name: `demo-${service.service}-1`, State: 'uncreated',
          Labels: { 'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml' },
        })));
      }
      assert.equal(request.method, 'POST');
      starts.push(await request.json());
      if (slow) await new Promise<void>((resolve, reject) => {
        const abort = () => { aborted++; reject(request.signal.reason); };
        if (request.signal.aborted) { abort(); return; }
        request.signal.addEventListener('abort', abort, { once: true });
        releases.push(() => { request.signal.removeEventListener('abort', abort); resolve(); });
      });
      return Response.json({ ok: true });
    } },
    STARTUP: { fetch: (request: Request) => coordinator.fetch(request, env, ctx) },
  };
  return {
    runtime, env, starts, releases,
    setServices(value: unknown) { services = value; },
    setReady(d: boolean, c: boolean) { docker = d; compose = c; },
    setSlow(value: boolean) { slow = value; },
    setWritable(value: boolean) { writable = value; },
    get aborted() { return aborted; }, get probes() { return probes; }, get stateReads() { return stateReads; },
    get saved() { return saved; },
    restartWorkerd() { coordinator = new ServiceStartupCoordinator(); },
    notify() { return env.STARTUP.fetch(new Request('http://startup/reconcile')); },
    async settle() { await Promise.all(background); },
  };
}

async function until(predicate: () => boolean) {
  for (let i = 0; i < 100; i++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 1));
  }
  assert(predicate(), 'background startup did not reach the expected state');
}

Deno.test('empty and invalid configured lists start nothing and do no Docker work', async () => {
  for (const services of [[], null, [null], [web, { project: 'demo' }], [{ ...web, path: '' }]]) {
    const f = fixture();
    f.setServices(services);
    assert.equal((await f.notify()).status, 202);
    await f.settle();
    assert.equal(f.starts.length, 0);
    assert.equal(f.probes, 0);
    assert.equal(f.stateReads, 0);
  }
});

Deno.test('configured starts wait for VM and both APIs, once per boot across workerd restarts', async () => {
  const f = fixture();
  f.setServices([web, web]);
  for (const phase of ['starting', 'restarting', 'degraded', 'diagnosing', 'stopped', 'failed']) {
    f.runtime.phase = phase;
    await f.notify();
    await f.settle();
    assert.equal(f.starts.length, 0);
  }
  f.runtime.phase = 'healthy';
  f.runtime.bootId = '';
  await f.notify();
  await f.settle();
  assert.equal(f.starts.length, 0);
  f.runtime.bootId = 'boot-1';
  for (const [docker, compose] of [[false, false], [true, false], [false, true]]) {
    f.setReady(docker, compose);
    await f.notify();
    await f.settle();
    assert.equal(f.starts.length, 0);
  }
  f.setReady(true, true);
  await Promise.all([f.notify(), f.notify()]);
  await f.settle();
  assert.deepEqual(f.starts, [{ service: 'web', path: '/stacks/demo/compose.yaml' }]);
  f.restartWorkerd();
  await f.notify();
  await f.settle();
  assert.equal(f.starts.length, 1);
  f.runtime.bootId = 'boot-2';
  await f.notify();
  await f.settle();
  assert.equal(f.starts.length, 2);
});

Deno.test('configured startup and separate app gateways share one background start', async () => {
  const f = fixture();
  f.setServices([web]);
  f.setSlow(true);
  assert.equal((await f.notify()).status, 202);
  await until(() => f.starts.length === 1);
  const service = { project: 'demo', service: 'web', configFiles: '/stacks/demo/compose.yaml' };
  const [http, tls] = await Promise.all([startApplication(service, f.env), startApplication(service, { ...f.env })]);
  assert(http.pending && tls.pending);
  assert.equal(f.starts.length, 1);
  // Lifecycle notifications answer while Compose's start request remains held.
  assert.equal((await f.notify()).status, 202);
  assert.equal(f.starts.length, 1);
  f.releases[0]();
  await Promise.all([http.promise, tls.promise, f.settle()]);
  assert.equal(http.pending, false);
  assert.equal(tls.pending, false);
});

Deno.test('project variants and replicas keep distinct starts in the shared coordinator', async () => {
  const f = fixture();
  const service = { project: 'demo', service: 'web', id: 'web-1', configFiles: '/stacks/demo/compose.yaml', number: 1 };
  const entries = await Promise.all([
    startApplication(service, f.env),
    startApplication({ ...service, id: 'other-1', configFiles: '/stacks/other/compose.yaml' }, f.env),
    startApplication({ ...service, id: 'web-2', number: 2 }, f.env),
  ]);
  await Promise.all(entries.map(entry => entry.promise));
  assert.deepEqual(f.starts.map(start => start.container), ['web-1', 'other-1', 'web-2']);
});

Deno.test('normal app responses coalesce readiness reports and a new start resets them', async () => {
  const f = fixture();
  const service = { project: 'demo', service: 'web', id: 'web-1', configFiles: '/stacks/demo/compose.yaml' };
  let reports = 0;
  const fetch = f.env.STARTUP.fetch;
  f.env.STARTUP.fetch = request => {
    if (new URL(request.url).pathname === '/ready') reports++;
    return fetch(request);
  };
  await Promise.all([applicationReady(service, f.env), applicationReady(service, f.env)]);
  await applicationReady(service, f.env);
  assert.equal(reports, 1);
  const start = await startApplication(service, f.env);
  await start.promise;
  await applicationReady(service, f.env);
  assert.equal(reports, 2);
});

Deno.test('stop aborts an in-flight start and recovery never drains the old boot queue', async () => {
  const f = fixture();
  f.setServices([web, worker]);
  f.setSlow(true);
  await f.notify();
  await until(() => f.starts.length === 1);
  f.runtime.phase = 'stopped';
  await f.notify();
  await f.settle();
  assert.equal(f.aborted, 1);
  assert.equal(f.starts.length, 1);
  f.setSlow(false);
  f.runtime.phase = 'healthy';
  f.runtime.bootId = 'boot-2';
  await f.notify();
  await f.settle();
  assert.deepEqual(f.starts.map(start => start.service), ['web', 'web', 'worker']);
  assert.equal(JSON.parse(f.saved!).bootId, 'boot-2');
});

Deno.test('an unwritable checkpoint prevents starts and can recover without replaying one', async () => {
  const f = fixture();
  f.setServices([web]);
  f.setWritable(false);
  await f.notify();
  await f.settle();
  assert.equal(f.starts.length, 0);
  f.setWritable(true);
  await f.notify();
  await f.settle();
  assert.equal(f.starts.length, 1);
});
