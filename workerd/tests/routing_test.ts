// Unit tests only: Docker, Compose, guest transport and upstream fetch are mocked.
import assert from 'node:assert/strict';
import gateway from '../gateway.js';
import appGatewayWorker from '../app-gateway.js';
import management from '../management.js';
import tlsGateway from '../tls-gateway.js';
import router from '../router.js';
import { surfaceRuntimeFailure } from '../runtime-status.js';
import { clientHelloServerName } from '../tls-client-hello.js';
import { resolveApplicationPort } from '../app-routing.js';
import { resolveApplicationService } from '../app-discovery.js';
import { applicationReady, applicationStarting, startApplication } from '../app-startup.js';
import { ServiceStartupCoordinator } from '../service-startup.js';

function withStartup<T extends object>(env: T) {
  if ('STARTUP' in env) return env;
  const coordinator = new ServiceStartupCoordinator();
  return Object.assign(env, { STARTUP: { fetch: (request: Request) =>
    coordinator.fetch(request, env, { waitUntil() {} }) } });
}

const appGateway = { fetch: (request: Request, env: object, ctx = { waitUntil(_promise: Promise<unknown>) {} }) =>
  appGatewayWorker.fetch(request, withStartup(env), ctx) };

interface TestContainer {
  Id: string;
  State?: string;
  Labels: Record<string, string>;
  Ports: { Type: string; PrivatePort: number; PublicPort?: number }[];
}

function composeProjects(containers: TestContainer[]) {
  const projects = new Map<string, Set<string>>();
  for (const container of containers) {
    const project = container.Labels['com.docker.compose.project'];
    if (!projects.has(project)) projects.set(project, new Set());
    const files = container.Labels['com.docker.compose.project.config_files'];
    if (files) projects.get(project)!.add(files);
  }
  return [...projects].map(([Name, files]) => ({ Name, ConfigFiles: [...files].join(',') }));
}

function composeContainers(containers: TestContainer[]) {
  return containers.map(container => ({
    ID: container.Id,
    Name: `${container.Labels['com.docker.compose.project']}-${container.Labels['com.docker.compose.service']}-${container.Labels['com.docker.compose.container-number'] || 1}`,
    Service: container.Labels['com.docker.compose.service'],
    State: container.State || 'running',
    Labels: container.Labels,
    Publishers: container.Ports.map(port => ({
      Protocol: port.Type, TargetPort: port.PrivatePort, PublishedPort: port.PublicPort || 0,
    })),
  }));
}

Deno.test('TLS ClientHello selects only its SNI hostname', () => {
  const hostname = new TextEncoder().encode('darc_darc.localhost');
  const name = new Uint8Array([0, 0, hostname.length, ...hostname]);
  const names = new Uint8Array([0, name.length, ...name]);
  const extension = new Uint8Array([0, 0, 0, names.length, ...names]);
  const body = new Uint8Array([
    3, 3, ...new Uint8Array(32), 0, 0, 2, 0x13, 1, 1, 0,
    0, extension.length, ...extension,
  ]);
  const handshake = new Uint8Array([1, 0, 0, body.length, ...body]);
  const record = new Uint8Array([22, 3, 1, 0, handshake.length, ...handshake]);
  assert.equal(clientHelloServerName(record.subarray(0, 10)), undefined);
  assert.equal(clientHelloServerName(record), 'darc_darc.localhost');
  assert.equal(clientHelloServerName(new Uint8Array([71, 69, 84, 32, 47])), null);
  const first = handshake.subarray(0, 20);
  const second = handshake.subarray(20);
  const fragmented = new Uint8Array([
    22, 3, 1, 0, first.length, ...first,
    22, 3, 1, 0, second.length, ...second,
  ]);
  assert.equal(clientHelloServerName(fragmented), 'darc_darc.localhost');
});

Deno.test('TLS gateway connects to the private terminator with an explicit address', async () => {
  for (const hostname of ['compose-ui.localhost', 'service.app.localhost']) {
    const encoded = new TextEncoder().encode(hostname);
    const name = new Uint8Array([0, 0, encoded.length, ...encoded]);
    const names = new Uint8Array([0, name.length, ...name]);
    const extension = new Uint8Array([0, 0, 0, names.length, ...names]);
    const body = new Uint8Array([3, 3, ...new Uint8Array(32), 0, 0, 2, 0x13, 1, 1, 0,
      0, extension.length, ...extension]);
    const handshake = new Uint8Array([1, 0, 0, body.length, ...body]);
    const hello = new Uint8Array([22, 3, 1, 0, handshake.length, ...handshake]);
    const writes: Uint8Array[] = [];
    const client = {
      readable: new ReadableStream<Uint8Array>({ start(controller) { controller.enqueue(hello); controller.close(); } }),
      writable: new WritableStream<Uint8Array>(),
      close: () => Promise.resolve(),
    };
    const upstream = {
      readable: new ReadableStream<Uint8Array>({ start(controller) { controller.close(); } }),
      writable: new WritableStream<Uint8Array>({ write(bytes) { writes.push(bytes); } }),
      close: () => Promise.resolve(),
    };
    let address: string | undefined;
    const env = {
      UI_TLS: { connect: (value: string) => { address = value; return Promise.resolve(upstream); } },
      ROUTER: { fetch: () => Promise.resolve(Response.json({
        id: 'service-1', service: 'service', project: 'tls-test',
        publishedPorts: [{ target: 3000, published: 8080 }],
      })) },
      COMPOSE: { fetch: () => Promise.resolve(Response.json({ services: {
        service: { ports: [{ target: 3000, published: 8080, app_protocol: 'http' }] },
      } })) },
    };
    await tlsGateway.connect(client, env);
    assert.equal(address, 'localhost:443');
    assert.deepEqual(writes[0], hello);
  }
});

Deno.test('management UI does not require a launcher session token', async () => {
  let ports = { http: 5196, https: 5194, publicHttpReady: true };
  const env = {
    MANAGEMENT: { fetch: () => Promise.resolve(new Response('compose-ui')) },
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json(ports)) },
  };
  const response = await gateway.fetch(new Request('http://127.0.0.1:8094/'), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'compose-ui');
  assert.equal(response.headers.get('set-cookie'), null);
  const navigation = () => gateway.fetch(new Request('http://127.0.0.1:8094/', {
    headers: { 'Sec-Fetch-Mode': 'navigate' },
  }), env);
  const fallback = await navigation();
  assert.equal(fallback.status, 307);
  assert.equal(fallback.headers.get('location'), 'http://compose-ui.localhost:5196/');
  assert.equal(fallback.headers.get('cache-control'), 'no-store');
  ports = { http: 80, https: 443, publicHttpReady: true };
  assert.equal((await navigation()).headers.get('location'), 'http://compose-ui.localhost/');
  ports = { http: 80, https: 443, publicHttpReady: false };
  const unavailable = await navigation();
  assert.equal(unavailable.status, 503);
  assert.match(await unavailable.text(), /selected HTTP port 80/);
  const missingStatus = { ...env, RUNTIME_STATUS: { fetch: () => Promise.resolve(new Response(null, { status: 404 })) } };
  const missingNavigation = await gateway.fetch(new Request('http://127.0.0.1:8094/', {
    headers: { 'Sec-Fetch-Mode': 'navigate' },
  }), missingStatus);
  assert.equal(missingNavigation.status, 503);
  assert.equal((await appGateway.fetch(new Request('http://compose-ui.localhost:5196/'), missingStatus)).status, 503);
  assert.equal((await appGateway.fetch(new Request('http://evil.test:5196/'), missingStatus)).status, 403);
  assert.equal((await gateway.fetch(new Request('http://web.localhost:8094/'), env)).status, 403);
});

Deno.test('Compose UI uses the shared HTTP and HTTPS application host', async () => {
  const env = {
    MANAGEMENT: { fetch: () => Promise.resolve(new Response('compose-ui')) },
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({ http: 5196, https: 5194 })) },
  };
  for (const protocol of ['http', 'https']) {
    const url = `${protocol}://compose-ui.localhost:${protocol === 'http' ? 5196 : 5194}/`;
    const response = await appGateway.fetch(new Request(url), env);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'compose-ui');
    assert.equal(response.headers.get('x-frame-options'), 'DENY');
    assert.equal((await appGateway.fetch(new Request(url, {
      headers: { Origin: 'https://evil.test' },
    }), env)).status, 403);
  }
});

Deno.test('signed Xe Computer origin can use only the Compose UI routes', async () => {
  const origin = 'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic';
  let forwarded: Request | undefined;
  const env = { MANAGEMENT: { fetch: (request: Request) => {
    forwarded = request;
    return Promise.resolve(request.method === 'POST'
      ? Response.json({ ok: true, path: 'development/darc-code' }, { status: 201 })
      : Response.json([]));
  } } };
  const preflight = await gateway.fetch(new Request('http://127.0.0.1:8094/v1.24/repos/checkout', {
    method: 'OPTIONS',
    headers: {
      Origin: origin,
      'Sec-Fetch-Site': 'cross-site',
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'content-type',
      'Access-Control-Request-Private-Network': 'true',
    },
  }), env);
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), origin);
  assert.equal(preflight.headers.get('access-control-allow-private-network'), 'true');

  const body = JSON.stringify({ url: 'https://github.com/Agent54/darc-code', path: 'development' });
  const checkout = await gateway.fetch(new Request('http://127.0.0.1:8094/v1.24/repos/checkout', {
    method: 'POST', body, headers: {
      Origin: origin, 'Sec-Fetch-Site': 'cross-site', 'Content-Type': 'application/json',
    },
  }), env);
  assert.equal(checkout.status, 201);
  assert.equal(checkout.headers.get('access-control-allow-origin'), origin);
  assert.equal(await forwarded?.text(), body);

  for (const path of ['/v1.24/ls?all=true', '/v1.24/config/demo?format=json', '/v1.24/ps/demo?all=true']) {
    const response = await gateway.fetch(new Request(`http://127.0.0.1:8094${path}`, {
      headers: { Origin: origin, 'Sec-Fetch-Site': 'cross-site' },
    }), env);
    assert.equal(response.status, 200, path);
    assert.equal(response.headers.get('access-control-allow-origin'), origin);
  }

  const readPreflight = await gateway.fetch(new Request('http://127.0.0.1:8094/v1.24/ls', {
    method: 'OPTIONS',
    headers: {
      Origin: origin,
      'Sec-Fetch-Site': 'cross-site',
      'Access-Control-Request-Method': 'GET',
      'Access-Control-Request-Private-Network': 'true',
    },
  }), env);
  assert.equal(readPreflight.status, 204);
  assert.equal(readPreflight.headers.get('access-control-allow-methods'), 'GET');

  const denied = await gateway.fetch(new Request('http://127.0.0.1:8094/v1.24/system', {
    headers: { Origin: origin, 'Sec-Fetch-Site': 'cross-site' },
  }), env);
  assert.equal(denied.status, 403);
});

Deno.test('signed Xe Computer origin uses Compose API on the HTTPS UI domain', async () => {
  const origin = 'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic';
  const url = 'https://compose-ui.localhost:5194';
  let upstream: Request | undefined;
  const env = {
    RUNTIME_STATUS: { fetch: (input: string) => Promise.resolve(Response.json(input.endsWith('status.json')
      ? { phase: 'healthy', message: 'Container runtime ready' }
      : { http: 5196, https: 5194, publicHttpReady: true })) },
    COMPOSE: { fetch: (request: Request) => {
      upstream = request;
      return Promise.resolve(Response.json(request.method === 'POST' ? { path: 'stacks/demo' } : []));
    } },
    ASSETS: { fetch: () => Promise.resolve(new Response('index')) },
    MANAGEMENT: { fetch: (request: Request) => management.fetch(request, env) },
  };
  const headers = { Origin: origin, 'Sec-Fetch-Site': 'cross-site' };
  const ports = await appGateway.fetch(new Request(`${url}/v1.24/app-ports`, { headers }), env);
  assert.equal(ports.status, 200);
  assert.equal(ports.headers.get('access-control-allow-origin'), origin);
  assert.deepEqual(await ports.json(), { http: 5196, https: 5194, publicHttpReady: true });
  for (const path of ['/v1.24/ls?all=true', '/v1.24/config/demo?format=json', '/v1.24/ps/demo?all=true']) {
    const response = await appGateway.fetch(new Request(`${url}${path}`, { headers }), env);
    assert.equal(response.status, 200, path);
    assert.equal(response.headers.get('access-control-allow-origin'), origin);
  }
  const preflight = await appGateway.fetch(new Request(`${url}/v1.24/repos/checkout`, {
    method: 'OPTIONS', headers: { ...headers,
      'Access-Control-Request-Method': 'POST',
      'Access-Control-Request-Headers': 'content-type',
      'Access-Control-Request-Private-Network': 'true',
    },
  }), env);
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), origin);
  assert.equal(preflight.headers.get('access-control-allow-private-network'), 'true');
  const checkout = await appGateway.fetch(new Request(`${url}/v1.24/repos/checkout`, {
    method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: '{"url":"https://example.com"}',
  }), env);
  assert.equal(checkout.status, 200);
  assert.equal(checkout.headers.get('access-control-allow-origin'), origin);
  assert.equal(upstream?.url, `${url}/v1.24/repos/checkout`);
  assert.equal((await appGateway.fetch(new Request(`${url}/v1.24/system`, { headers }), env)).status, 403);
  assert.equal((await appGateway.fetch(new Request(`${url}/v1.24/ls`, {
    headers: { Origin: 'https://evil.test', 'Sec-Fetch-Site': 'cross-site' },
  }), env)).status, 403);
  assert.equal((await appGateway.fetch(new Request('http://compose-ui.localhost:5196/v1.24/ls', { headers }), env)).status, 403);
});

Deno.test('runtime failures are enriched only while the supervisor reports an outage', async () => {
  let phase = 'healthy';
  const env = { RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({
    phase,
    message: phase === 'healthy' ? 'Container runtime ready' : 'Container VM ran out of memory; restarting…',
    reason: phase === 'healthy' ? null : 'oom',
  })) } };
  const applicationFailure = Response.json({ error: 'build_failed' }, { status: 500 });
  const healthyFailure = await surfaceRuntimeFailure(applicationFailure, env);
  assert.equal((await healthyFailure.json()).error, 'build_failed');
  const navigation = new Request('https://service.app.localhost/', { headers: { Accept: 'text/html' } });
  const upstreamFailure = new Response('application error', { status: 503 });
  assert.equal(await surfaceRuntimeFailure(upstreamFailure, env, navigation), upstreamFailure);
  phase = 'restarting';
  const runtimeFailure = await surfaceRuntimeFailure(Response.json({ error: 'backend EOF' }, { status: 500 }), env);
  assert.equal(runtimeFailure.status, 503);
  assert.equal((await runtimeFailure.json()).error, 'container_runtime_oom');
  const browserFailure = await surfaceRuntimeFailure(new Response('backend EOF', { status: 500 }), env, navigation);
  assert.match(browserFailure.headers.get('content-type')!, /text\/html/);
  assert.match(await browserFailure.text(), /Container VM ran out of memory; restarting…/);
});

Deno.test('Compose management answers during boot without contacting a stalled Docker backend', async () => {
  let runtime = { phase: 'starting', message: 'Starting container runtime…' };
  let forwarded = 0;
  const env = {
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json(runtime)) },
    COMPOSE: { fetch: () => { forwarded++; return new Promise<Response>(() => {}); } },
    ASSETS: { fetch: () => Promise.resolve(new Response('compose-ui')) },
  };
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      (async () => {
        for (const phase of ['starting', 'restarting', 'degraded', 'failed', 'stopped']) {
          runtime = { ...runtime, phase };
          for (const path of ['ls', 'system', 'ps/demo', 'start/demo/container']) {
            const response = await management.fetch(new Request(`http://compose-ui.localhost/v1.24/${path}`), env);
            assert.equal(response.status, 503);
            assert.equal(response.headers.get('retry-after'), '2');
            assert.equal((await response.json()).runtime.phase, phase);
          }
        }
      })(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('API waited for Docker during startup')), 1000);
      }),
    ]);
  } finally { clearTimeout(timer); }
  assert.equal(forwarded, 0);
  assert.equal(await (await management.fetch(new Request('http://compose-ui.localhost/'), env)).text(), 'compose-ui');
  assert.equal((await (await management.fetch(new Request('http://compose-ui.localhost/v1.24/runtime-status'), env)).json()).phase, 'stopped');

  const available = { ...env, COMPOSE: { fetch: () => { forwarded++; return Promise.resolve(Response.json({ ok: true })); } } };
  for (const path of ['', '_ping', 'repos/checkout']) {
    assert.equal((await management.fetch(new Request(`http://compose-ui.localhost/v1.24/${path}`), available)).status, 200);
  }
  runtime = { phase: 'healthy', message: 'Container runtime ready' };
  assert.equal((await management.fetch(new Request('http://compose-ui.localhost/v1.24/ls'), available)).status, 200);
  assert.equal(forwarded, 4);
});

Deno.test('browser app requests show the runtime loader until Compose and the VM recover', async t => {
  let runtime = {
    phase: 'starting', message: 'Starting container runtime…', reason: null as string | null,
    hostResources: { cpuCount: 12, memoryTotalBytes: 34359738368 },
    vmResources: { diskLogicalBytes: 32212254720 },
  };
  let statusAvailable = true;
  let composeAvailable = false;
  let upstreamStatus = 503;
  const env = {
    RUNTIME_STATUS: { fetch: (input: string) => {
      if (input.endsWith('app-ports.json')) return Promise.resolve(Response.json({ http: 80, https: 443 }));
      if (!statusAvailable) throw new Error('Runtime status unavailable');
      return Promise.resolve(Response.json(runtime));
    } },
    COMPOSE: { fetch: (input: string) => {
      if (!composeAvailable) throw new Error('Compose connection refused');
      const url = new URL(input);
      return Promise.resolve(Response.json(url.pathname === '/v1.24/ls'
        ? [{ Name: 'demo' }] : url.pathname.startsWith('/v1.24/ps/')
        ? [{ ID: 'web-1', Name: 'demo-web-1', Service: 'web', State: 'running',
          Publishers: [{ TargetPort: 3000, PublishedPort: 8080, Protocol: 'tcp' }] }]
        : { services: { web: { ports: [{ target: 3000, published: '8080' }] } } }));
    } },
    ROUTER: { fetch: () => Promise.resolve(new Response('application response', { status: upstreamStatus })) },
  };
  const request = (options: RequestInit = {}, scheme = 'https') =>
    appGateway.fetch(new Request(`${scheme}://web--p8080.app.localhost/deep/link?q=1`, options), env);
  await t.step('HTTP and HTTPS navigations get a no-store loader with an automatic retry', async () => {
    for (const scheme of ['http', 'https']) {
      const response = await request({ headers: { Accept: 'text/html', 'Sec-Fetch-Mode': 'navigate' } }, scheme);
      assert.equal(response.status, 503);
      assert.match(response.headers.get('content-type')!, /text\/html/);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      assert.equal(response.headers.get('retry-after'), '2');
      assert.match(response.headers.get('content-security-policy')!, /default-src 'none'/);
      const html = await response.text();
      assert.match(html, /<h1>Container runtime<\/h1>/);
      assert.match(html, /Starting container runtime…/);
      assert.match(html, /--background: #000000/);
      assert.match(html, /http-equiv="refresh" content="2"/);
    }
    for (const accept of ['text/html', 'application/json']) {
      const head = await request({ method: 'HEAD', headers: { Accept: accept } });
      assert.equal(head.status, 503);
      assert.equal(await head.text(), '');
    }
  });
  await t.step('API calls and upgrades keep the runtime JSON payload', async () => {
    const cases: RequestInit[] = [
      { headers: { Accept: 'application/json' } },
      { method: 'POST', headers: { Accept: 'text/html' }, body: 'must not replay' },
      { headers: { Upgrade: 'websocket' } },
    ];
    for (const options of cases) {
      const response = await request(options);
      assert.equal(response.status, 503);
      assert.match(response.headers.get('content-type')!, /application\/json/);
      assert.deepEqual(await response.json(), {
        ok: false, error: 'container_runtime_unavailable', message: runtime.message, runtime,
      });
    }
    const api = await management.fetch(new Request('https://compose-ui.localhost/v1.24/ls', {
      headers: { Accept: 'text/html' },
    }), env);
    assert.equal((await api.json()).error, 'container_runtime_unavailable');
  });
  await t.step('recovery phases retry and terminal failures display escaped details', async () => {
    for (const phase of ['degraded', 'diagnosing', 'restarting', 'failed', 'stopped']) {
      runtime = { ...runtime, phase, message: 'VM <failed> & "retry"', reason: 'oom' };
      const html = await (await request()).text();
      assert.match(html, /VM &lt;failed&gt; &amp; &quot;retry&quot;/);
      assert.doesNotMatch(html, /VM <failed>/);
      if (['failed', 'stopped'].includes(phase)) {
        assert.doesNotMatch(html, /http-equiv="refresh"/);
        assert.match(html, /Try again/);
      } else assert.match(html, /http-equiv="refresh" content="2"/);
      assert.equal((await (await request({ headers: { Accept: 'application/json' } })).json()).error, 'container_runtime_oom');
    }
  });
  await t.step('missing status and Compose startup after VM readiness still show the loader', async () => {
    statusAvailable = false;
    assert.match(await (await request()).text(), /Xe Launcher will retry automatically/);
    statusAvailable = true;
    runtime = { ...runtime, phase: 'healthy', message: 'Container runtime ready', reason: null };
    assert.match(await (await request()).text(), /Container services are unavailable/);
  });
  await t.step('router failures during runtime startup also show HTML and recovery reaches the app', async () => {
    composeAvailable = true;
    runtime = { ...runtime, phase: 'starting', message: 'Starting container runtime…' };
    assert.match(await (await request()).text(), /Starting container runtime…/);
    runtime = { ...runtime, phase: 'healthy', message: 'Container runtime ready' };
    upstreamStatus = 200;
    const ready = await request();
    assert.equal(ready.status, 200);
    assert.equal(await ready.text(), 'application response');
  });
});

Deno.test('application port selection', async t => {
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  const container = {
    Id: 'web-1', State: 'running', Labels: {
      'com.docker.compose.service': 'service', 'com.docker.compose.project': 'demo',
      'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml',
      'com.docker.compose.container-number': '1',
    },
    // Deliberately differs from YAML order; includes dual-stack duplicates and UDP.
    Ports: [
      { Type: 'tcp', PrivatePort: 3000, PublicPort: 8080 },
      { Type: 'tcp', PrivatePort: 9000, PublicPort: 9090 },
      { Type: 'tcp', PrivatePort: 9000, PublicPort: 9090 },
      { Type: 'tcp', PrivatePort: 9443, PublicPort: 9443 },
      { Type: 'udp', PrivatePort: 5353, PublicPort: 5353 },
      { Type: 'tcp', PrivatePort: 7000 },
    ],
    NetworkSettings: { Networks: { default: { IPAddress: '172.18.0.2' } } },
  };
  let containers = [container];
  let ports = [
    { name: 'metrics', target: 9000, published: '9090', protocol: 'tcp' },
    { name: 'web', target: 3000, published: '8080', protocol: 'tcp', app_protocol: 'http' },
    { name: 'secure', target: 9443, published: '9443', protocol: 'tcp', app_protocol: 'https' },
    { name: 'dns', target: 5353, published: '5353', protocol: 'udp' },
  ];
  let configStatus = 200;
  let guestDown = false;
  let listenerPorts = { http: 80, https: 443 };
  const guestEnv = { DOCKER: { fetch: () => Promise.resolve(Response.json(containers)) } };
  const env = {
    ROUTER: { fetch: (input: Request | string) => {
      if (guestDown) throw new Error('Guest unavailable');
      return router.fetch(input instanceof Request ? input : new Request(input), guestEnv);
    } },
    COMPOSE: { fetch: (input: string) => {
      const url = new URL(input);
      if (url.pathname === '/v1.24/ls') return Promise.resolve(Response.json(composeProjects(containers)));
      if (url.pathname.startsWith('/v1.24/ps/')) {
        assert.equal(url.searchParams.get('all'), 'true');
        return Promise.resolve(Response.json(composeContainers(containers.filter(container =>
          container.Labels['com.docker.compose.project'] === url.pathname.split('/').at(-1)))));
      }
      assert.match(url.pathname, /^\/v1.24\/config\/(?:demo|other)$/);
      assert.equal(url.searchParams.get('format'), 'json');
      assert.equal(url.searchParams.get('path'), '/stacks/demo/compose.yaml');
      return Promise.resolve(Response.json({ services: { service: { ports } } }, { status: configStatus }));
    } },
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json(listenerPorts)) },
  };
  globalThis.fetch = (input: RequestInfo | URL) => {
    assert(input instanceof Request);
    return Promise.resolve(Response.json({ url: input.url, headers: Object.fromEntries(input.headers) }));
  };
  function request(host = 'service.localhost', headers?: Record<string, string>) {
    const authority = listenerPorts.http === 80 ? host : `${host}:${listenerPorts.http}`;
    return appGateway.fetch(new Request(`http://${authority}/hello?q=1`, { headers }), env);
  }
  try {
    await t.step('default follows YAML order rather than Docker or numeric order', async () => {
      assert.equal((await (await request()).json()).url, 'http://172.18.0.2:9000/hello?q=1');
    });
    await t.step('numeric selector uses the published port, never an index or container port', async () => {
      assert.equal((await (await request('service.8080.localhost')).json()).url, 'http://172.18.0.2:3000/hello?q=1');
      for (const selector of ['0', '1', '3', '3000', '65536', '5353', '7000']) {
        assert.equal((await request(`service.${selector}.localhost`)).status, 404, selector);
      }
    });
    await t.step('standard Compose port names select their target ports', async () => {
      assert.equal((await (await request('service.web.localhost')).json()).url, 'http://172.18.0.2:3000/hello?q=1');
      assert.equal((await request('service.dns.localhost')).status, 404);
      assert.equal((await request('service.missing.localhost')).status, 404);
    });
    await t.step('the HTTPS listener terminates HTTP apps and preserves their public scheme', async () => {
      const response = await appGateway.fetch(new Request('https://service.web.localhost/hello?q=1'), env);
      assert.equal(response.status, 200);
      const result = await response.json();
      assert.equal(result.url, 'http://172.18.0.2:3000/hello?q=1');
      assert.equal(result.headers['x-forwarded-proto'], 'https');
      assert.equal(result.headers['x-xe-origin-proto'], undefined);
      assert.equal(result.headers['x-xe-public-host'], undefined);
      const posted = await appGateway.fetch(new Request('https://service.web.localhost/submit', {
        method: 'POST', body: 'payload',
      }), env);
      assert.equal(posted.status, 200);
      const alias = await appGateway.fetch(new Request('https://service.app.localhost/hello'), env);
      assert.equal(alias.status, 200);
      const aliased = await alias.json();
      assert.equal(aliased.url, 'http://172.18.0.2:9000/hello');
      assert.equal(aliased.headers['x-forwarded-host'], 'service.app.localhost');
    });
    await t.step('certificate-covered HTTPS aliases select published ports', async () => {
      const response = await appGateway.fetch(new Request('https://service--p8080.app.localhost/hello'), env);
      assert.equal(response.status, 200);
      const result = await response.json();
      assert.equal(result.url, 'http://172.18.0.2:3000/hello');
      assert.equal(result.headers['x-forwarded-host'], 'service--p8080.app.localhost');
      assert.equal(result.headers['x-forwarded-proto'], 'https');
      const projectRoute = await appGateway.fetch(new Request('https://service_demo--p8080.app.localhost/hello'), env);
      assert.equal((await projectRoute.json()).url, 'http://172.18.0.2:3000/hello');
      const named = await appGateway.fetch(new Request('https://service--nweb.app.localhost/hello'), env);
      assert.equal((await named.json()).url, 'http://172.18.0.2:3000/hello');
      const secure = await appGateway.fetch(new Request('https://service--p9443.app.localhost/hello'), env);
      assert.equal(secure.status, 307);
      assert.equal(secure.headers.get('location'), 'https://service.9443.localhost/hello');
      const namedSecure = await appGateway.fetch(new Request('https://service--nsecure.app.localhost/hello'), env);
      assert.equal(namedSecure.headers.get('location'), 'https://service.secure.localhost/hello');
    });
    await t.step('HTTPS application ports redirect to the shared TLS endpoint', async () => {
      const named = await request('service.secure.localhost');
      assert.equal(named.status, 307);
      assert.equal(named.headers.get('location'), 'https://service.secure.localhost/hello?q=1');
      const numeric = await request('service.9443.localhost');
      assert.equal(numeric.status, 307);
      assert.equal(numeric.headers.get('location'), 'https://service.9443.localhost/hello?q=1');
      const route = await resolveApplicationPort('service.secure.localhost', env);
      assert.equal(route?.port.target, 9443);
      assert.equal(route?.protocol, 'https');
    });
    await t.step('a default HTTPS port uses the canonical port-free hostname', async () => {
      ports = [ports[2], ports[0], ports[1], ports[3]];
      now += 3000;
      const response = await request();
      assert.equal(response.status, 307);
      assert.equal(response.headers.get('location'), 'https://service.localhost/hello?q=1');
      const route = await resolveApplicationPort('service.localhost', env);
      assert.equal(route?.port.target, 9443);
      assert.equal(route?.protocol, 'https');
      const alias = await appGateway.fetch(new Request('https://service.app.localhost/hello'), env);
      assert.equal(alias.status, 307);
      assert.equal(alias.headers.get('location'), 'https://service.localhost/hello');
      ports = [ports[1], ports[2], ports[0], ports[3]];
      now += 3000;
    });
    await t.step('fallback listeners preserve their ports in HTTPS redirects', async () => {
      listenerPorts = { http: 5196, https: 5194 };
      const http = await (await request('service.web.localhost', { 'x-xe-public-host': 'evil.test:1234' })).json();
      assert.equal(http.headers['x-forwarded-host'], 'service.web.localhost:5196');
      assert.equal(http.headers['x-forwarded-proto'], 'http');
      assert.equal(http.headers['x-xe-public-host'], undefined);
      const https = await (await appGateway.fetch(new Request('https://service.web.localhost:5194/hello'), env)).json();
      assert.equal(https.headers['x-forwarded-host'], 'service.web.localhost:5194');
      assert.equal(https.headers['x-forwarded-proto'], 'https');
      const response = await request('service.secure.localhost');
      assert.equal(response.status, 307);
      assert.equal(response.headers.get('location'), 'https://service.secure.localhost:5194/hello?q=1');
      assert.equal((await appGateway.fetch(new Request('http://service.secure.localhost/'), env)).status, 403);
      listenerPorts = { http: 80, https: 443 };
    });
    await t.step('caller cannot override selected ports and internal headers do not reach apps', async () => {
      const response = await request('service.web.localhost', {
        'x-xe-target-port': '7000', 'x-xe-container-id': 'forged', 'x-xe-published-port': '1234',
      });
      const result = await response.json();
      assert.equal(result.url, 'http://172.18.0.2:3000/hello?q=1');
      assert.equal(result.headers['x-xe-target-port'], undefined);
      assert.equal(result.headers['x-xe-container-id'], undefined);
      assert.equal(result.headers['x-xe-published-port'], undefined);
      assert.equal(result.headers['x-forwarded-host'], 'service.web.localhost');
      assert.equal((await request('localhost')).status, 403);
      assert.equal((await request('api.moby.localhost')).status, 403);
    });
    await t.step('configuration changes refresh names and default order', async () => {
      ports = [ports[1], { ...ports[0], name: 'monitor' }, ports[2], ports[3]];
      now += 3000;
      assert.equal((await (await request()).json()).url, 'http://172.18.0.2:3000/hello?q=1');
      assert.equal((await request('service.metrics.localhost')).status, 404);
      assert.equal((await request('service.monitor.localhost')).status, 200);
    });
    await t.step('duplicate port names fail instead of picking an arbitrary port', async () => {
      ports = ports.map(p => ({ ...p, name: 'web' }));
      now += 3000;
      assert.equal((await request('service.web.localhost')).status, 404);
    });
    await t.step('a port named localhost is distinct from the default route', async () => {
      ports = [{ ...ports[0], target: 9000, published: '9090', name: 'first' },
        { ...ports[1], target: 3000, published: '8080', name: 'localhost' }];
      now += 3000;
      assert.equal((await (await request('service.localhost.localhost')).json()).url, 'http://172.18.0.2:3000/hello?q=1');
      assert.equal((await (await request()).json()).url, 'http://172.18.0.2:9000/hello?q=1');
    });
    await t.step('first YAML port must be published on the running container', async () => {
      ports = [{ name: 'internal', target: 7000, published: '7070', protocol: 'tcp' }, ...ports];
      now += 3000;
      assert.equal((await request()).status, 404);
    });
    await t.step('missing configuration fails default/name routes but numeric routes still work', async () => {
      configStatus = 503;
      now += 3000;
      assert.equal((await request()).status, 503);
      assert.equal((await request('service.web.localhost')).status, 503);
      assert.equal((await request('service.8080.localhost')).status, 200);
      configStatus = 200;
    });
    await t.step('ambiguous services require a project and replicas keep their suffix', async () => {
      containers = [container, { ...container, Id: 'other', Labels: { ...container.Labels, 'com.docker.compose.project': 'other' } }];
      now += 3000;
      assert.equal((await request('service.8080.localhost')).status, 404);
      assert.equal((await request('service_demo.8080.localhost')).status, 200);
      containers = [{ ...container, Labels: { ...container.Labels, 'com.docker.compose.container-number': '2' } }];
      now += 3000;
      assert.equal((await request('service_demo_2.8080.localhost')).status, 200);
      assert.equal((await request('service.localhost')).status, 404);
    });
    await t.step('guest outage returns a retryable failure', async () => {
      ports = [{ name: 'web', target: 3000, published: '8080', protocol: 'tcp' }];
      now += 3000;
      guestDown = true;
      assert.equal((await request('service_demo_2.localhost')).status, 503);
      assert.equal((await request('service_demo_2.8080.localhost')).status, 503);
    });
  } finally {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
  }
});

Deno.test('application access starts exactly the selected stopped container', async t => {
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  let now = originalNow() + 100_000;
  Date.now = () => now;
  const labels: Record<string, string> = {
    'com.docker.compose.service': 'sleeping', 'com.docker.compose.project': 'startup-test',
    'com.docker.compose.project.config_files': '/stacks/startup-test/compose.yaml',
    'com.docker.compose.container-number': '1',
  };
  const first = { Id: 'sleeping-1', State: 'exited', Labels: labels,
    Ports: [] as { Type: string; PrivatePort: number; PublicPort: number }[],
    NetworkSettings: { Networks: { default: { IPAddress: '172.18.0.3' } } } };
  let containers = [first];
  const starts: { path: string; body: unknown }[] = [];
  const background: Promise<unknown>[] = [];
  const ctx = { waitUntil(promise: Promise<unknown>) { background.push(promise); } };
  let releaseStart: (() => void) | undefined;
  let startStatus = 200;
  let upstreamReady = false;
  let upstreamStatus = 200;
  let upstreamRequests = 0;
  const guestEnv = { DOCKER: { fetch: (input: string) => {
    const url = new URL(input);
    if (url.pathname === '/containers/json') {
      assert.equal(url.searchParams.get('all'), 'true');
      return Promise.resolve(Response.json(containers));
    }
    assert.match(url.pathname, /^\/containers\/sleeping-\d+\/json$/);
    return Promise.resolve(Response.json({ HostConfig: { PortBindings: {
      '3000/tcp': [{ HostIp: '', HostPort: '8080' }],
      '3000/udp': [{ HostIp: '', HostPort: '5353' }],
    } } }));
  } } };
  const env = {
    ROUTER: { fetch: (input: Request | string) => router.fetch(input instanceof Request ? input : new Request(input), guestEnv) },
    COMPOSE: { fetch: async (input: Request | string) => {
      const request = input instanceof Request ? input : new Request(input);
      const url = new URL(request.url);
      if (url.pathname === '/v1.24/ls') return Response.json(composeProjects(containers));
      if (url.pathname.startsWith('/v1.24/ps/')) {
        return Response.json(composeContainers(containers.filter(container =>
          container.Labels['com.docker.compose.project'] === url.pathname.split('/').at(-1))));
      }
      if (request.method === 'POST') {
        starts.push({ path: url.pathname, body: await request.json() });
        if (releaseStart) await new Promise<void>(resolve => { releaseStart = resolve; });
        return Response.json({ ok: startStatus === 200 }, { status: startStatus });
      }
      assert.match(url.pathname, /^\/v1.24\/config\/(?:startup-test|other)$/);
      return Response.json({ services: { sleeping: { ports: [{ name: 'web', target: 3000, published: '8080' }] } } });
    } },
    RUNTIME_STATUS: { fetch: (input: string) => Promise.resolve(Response.json(input.endsWith('app-ports.json')
      ? { http: 80, https: 443 } : { phase: 'healthy', message: 'ready' })) },
  };
  function request(host = 'sleeping.localhost', options: RequestInit = {}) {
    return appGateway.fetch(new Request(`https://${host}/deep/link?q=1`, options), env, ctx);
  }
  globalThis.fetch = () => {
    upstreamRequests++;
    if (!upstreamReady) throw new Error('Connection refused');
    return Promise.resolve(new Response('application response', { status: upstreamStatus }));
  };
  try {
    await t.step('invalid routes do not start any container', async () => {
      for (const host of ['missing.localhost', 'sleeping.missing.localhost', 'sleeping.3000.localhost', 'sleeping.5353.localhost']) {
        const response = await request(host);
        assert.equal(response.status, 404, host);
        assert.equal(response.headers.get('cache-control'), 'no-store', host);
      }
      assert.equal(starts.length, 0);
    });
    await t.step('all selectors share one background start and return the black loader immediately', async () => {
      releaseStart = () => {};
      const responses = await Promise.all([
        request(), request('sleeping.web.localhost'), request('sleeping.8080.localhost'),
        request('sleeping_startup-test--nweb.app.localhost'), request('sleeping--p8080.app.localhost'),
      ]);
      for (const response of responses) {
        assert.equal(response.status, 503);
        assert.equal(response.headers.get('cache-control'), 'no-store');
        assert.equal(response.headers.get('retry-after'), '2');
        assert.match(response.headers.get('content-type')!, /text\/html/);
        const html = await response.text();
        assert.match(html, /<h1>sleeping<\/h1>/);
        assert.match(html, /Starting…/);
        assert.match(html, /--background: #000000/);
        assert.match(html, /http-equiv="refresh" content="2"/);
      }
      assert.deepEqual(starts, [{ path: '/v1.24/start/startup-test/container',
        body: { container: 'sleeping-1', path: '/stacks/startup-test/compose.yaml' } }]);
      assert.equal(upstreamRequests, 0);
      releaseStart!();
      releaseStart = undefined;
      await Promise.all(background);
    });
    await t.step('POST and WebSocket requests get retryable JSON; HEAD has no body', async () => {
      const posted = await request('sleeping.localhost', { method: 'POST', body: 'must not replay' });
      assert.equal(posted.status, 503);
      assert.equal((await posted.json()).state, 'starting');
      const upgrade = await request('sleeping.localhost', { headers: { Upgrade: 'websocket' } });
      assert.equal((await upgrade.json()).state, 'starting');
      const head = await request('sleeping.localhost', { method: 'HEAD' });
      assert.equal(head.status, 503);
      assert.equal(await head.text(), '');
      assert.equal(starts.length, 1);
    });
    await t.step('the loader survives connection refusal until the application is reachable', async () => {
      containers = [{ ...first, State: 'running', Ports: [{ Type: 'tcp', PrivatePort: 3000, PublicPort: 8080 }] }];
      now += 3000;
      assert.match(await (await request()).text(), /Starting…/);
      assert.equal(starts.length, 1);
      upstreamReady = true;
      upstreamStatus = 503;
      assert.equal(await (await request()).text(), 'application response', 'application errors are not replaced');
      upstreamStatus = 200;
      const ready = await request();
      assert.equal(ready.status, 200);
      assert.equal(await ready.text(), 'application response');
    });
    await t.step('created containers and replica URLs start only that exact instance', async () => {
      containers = [first, { ...first, Id: 'sleeping-2', State: 'created',
        Labels: { ...labels, 'com.docker.compose.container-number': '2' } }];
      now += 3000;
      assert.equal((await request('sleeping_startup-test_2--p8080.app.localhost')).status, 503);
      await Promise.all(background);
      assert.equal(starts.length, 2);
      assert.deepEqual(starts[1].body, { container: 'sleeping-2', path: '/stacks/startup-test/compose.yaml' });
    });
    await t.step('start failures remain visible and never fall back to a service-wide start', async () => {
      containers = [{ ...first, Id: 'sleeping-3', State: 'stopped' }];
      now += 3000;
      startStatus = 500;
      await request('sleeping.8080.localhost');
      await Promise.all(background);
      const response = await request('sleeping.8080.localhost');
      const html = await response.text();
      assert.equal(response.status, 503);
      assert.match(html, /Compose returned HTTP 500/);
      assert.doesNotMatch(html, /http-equiv="refresh"/);
      assert.equal(starts.length, 3);
      startStatus = 200;
      now += 11_000;
      await request();
      await Promise.all(background);
      assert.equal(starts.length, 4, 'a later retry may start the same container again');
    });
    await t.step('paused, restarting, ambiguous and one-off containers are never started', async () => {
      const before = starts.length;
      for (const state of ['paused', 'restarting', 'dead', 'removing']) {
        containers = [{ ...first, State: state }];
        now += 3000;
        assert.equal((await request()).status, 503);
      }
      containers = [first, { ...first, Id: 'sleeping-4', Labels: { ...labels, 'com.docker.compose.project': 'other' } }];
      now += 3000;
      assert.equal((await request()).status, 404);
      containers = [{ ...first, Labels: { ...labels, 'com.docker.compose.oneoff': 'True' } }];
      now += 3000;
      assert.equal((await request()).status, 404);
      assert.equal(starts.length, before);
    });
  } finally {
    releaseStart?.();
    await Promise.all(background);
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
  }
});

Deno.test('startup errors reach the loader and API safely', async () => {
  const detail = 'No such image: <agenda-agenda> & "latest"';
  const cases = [
    { fetch: () => Response.json({ error: detail, message: 'other' }, { status: 404 }),
      message: `Compose returned HTTP 404: ${detail}` },
    { fetch: () => Response.json({ message: 'build failed' }, { status: 500 }),
      message: 'Compose returned HTTP 500: build failed' },
    { fetch: () => new Response('daemon unavailable', { status: 503, headers: { 'Content-Type': 'text/plain' } }),
      message: 'Compose returned HTTP 503: daemon unavailable' },
    { fetch: () => new Response('<html>proxy error</html>', { status: 502, headers: { 'Content-Type': 'text/html' } }),
      message: 'Compose returned HTTP 502 while starting this app.' },
    { fetch: () => { throw new TypeError('Compose connection refused'); }, message: 'Compose connection refused' },
    { fetch: () => { throw new DOMException('signal timed out', 'TimeoutError'); }, message: 'Starting this app timed out.' },
  ];
  for (const [index, test] of cases.entries()) {
    const service = { id: `failure-${index}`, service: 'agenda', project: 'startup-errors', state: 'uncreated' };
    const env = withStartup({ COMPOSE: { fetch: async () => test.fetch() } });
    const start = await startApplication(service, env);
    try {
      await start.promise;
      assert.equal(start.pending, false);
      assert.equal(start.error, test.message);
      const response = applicationStarting(new Request('https://agenda.app.localhost/'), service, start.error);
      assert.equal(response.status, 503);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      const html = await response.text();
      assert.doesNotMatch(html, /http-equiv="refresh"/);
      if (index === 0) {
        assert.match(html, /No such image: &lt;agenda-agenda&gt; &amp; &quot;latest&quot;/);
        assert.doesNotMatch(html, /<agenda-agenda>/);
      } else assert(html.includes(test.message));
      const api = applicationStarting(new Request('https://agenda.app.localhost/', {
        headers: { Accept: 'application/json' },
      }), service, start.error);
      assert.deepEqual(await api.json(), { app: 'agenda', state: 'failed', message: test.message });
    } finally { await applicationReady(service, env); }
  }
});

Deno.test('apps wait for runtime readiness, while existing containers need no router build gate', async () => {
  const service = { id: '', service: 'agenda', project: 'readiness-test', state: 'uncreated' };
  let phase = 'starting';
  let routerReady = false;
  let starts = 0;
  let release: (() => void) | undefined;
  const env = withStartup({
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({ phase, message: 'Starting container runtime…' })) },
    ROUTER: { fetch: (request: Request) => {
      assert.equal(new URL(request.url).pathname, '/__xe_router_health');
      return Promise.resolve(new Response(null, { status: routerReady ? 200 : 503 }));
    } },
    COMPOSE: { fetch: () => {
      starts++;
      return new Promise<Response>(resolve => { release = () => resolve(Response.json({ ok: true })); });
    } },
  });
  try {
    for (phase of ['starting', 'restarting', 'degraded', 'diagnosing']) {
      const deferred = await startApplication(service, env);
      await deferred.promise;
      const response = applicationStarting(new Request('https://agenda.app.localhost/'), service, deferred.error, deferred.message);
      const html = await response.text();
      assert.match(html, /<h1>agenda<\/h1>/);
      assert.match(html, /Starting container runtime…/);
      assert.match(html, /http-equiv="refresh" content="2"/);
      assert.equal(starts, 0);
    }

    phase = 'healthy';
    const existing = await startApplication({ ...service, id: 'readiness-existing', state: 'exited' }, env);
    assert.equal(starts, 1, 'an existing container does not need a build readiness gate');
    release!();
    await existing.promise;
    await applicationReady({ ...service, id: 'readiness-existing' }, env);

    const waitingForRouter = await startApplication(service, env);
    assert.equal(waitingForRouter.message, 'Starting application router…');
    assert.equal(starts, 1, 'the guest router must also be ready before building');
    routerReady = true;
    const [first, second] = await Promise.all([startApplication(service, env), startApplication(service, env)]);
    assert.equal(first.pending, second.pending);
    assert.equal(starts, 2);
    release!();
    await first.promise;
  } finally {
    release?.();
    await applicationReady(service, env);
    await applicationReady({ ...service, id: 'readiness-existing' }, env);
  }
});

Deno.test('Agenda URL discovers an uncreated app and shares its single-container creation', async () => {
  const originalNow = Date.now;
  let now = originalNow() + 300_000;
  Date.now = () => now;
  const background: Promise<unknown>[] = [];
  const ctx = { waitUntil(promise: Promise<unknown>) { background.push(promise); } };
  const configFiles = '/stacks/calender/docker-compose.yaml';
  const starts: { path: string; body: unknown }[] = [];
  let state = 'uncreated';
  let release: (() => void) | undefined;
  const requests: string[] = [];
  const env = {
    ROUTER: { fetch: (input: Request | string) => {
      const request = input instanceof Request ? input : new Request(input);
      if (new URL(request.url).hostname === 'localhost') {
        assert.equal(new URL(request.url).pathname, '/__xe_router_health', 'only the lightweight health probe may query the guest');
        return Promise.resolve(new Response('ready'));
      }
      assert.equal(request.headers.get('x-xe-container-id'), 'agenda-new-id');
      assert.equal(request.headers.get('x-xe-target-port'), '5173');
      return Promise.resolve(state === 'ready' ? new Response('agenda is ready') :
        new Response('connection refused', { status: 503, headers: { 'x-xe-router-unavailable': 'true' } }));
    } },
    COMPOSE: { fetch: async (input: Request | string) => {
      const request = input instanceof Request ? input : new Request(input);
      const url = new URL(request.url);
      requests.push(url.pathname);
      if (url.pathname === '/v1.24/ls') return Response.json([
        { Name: 'agenda', ConfigFiles: configFiles },
        { Name: 'unrelated', ConfigFiles: '/stacks/other/compose.yaml' },
      ]);
      if (url.pathname === '/v1.24/ps/agenda') {
        assert.equal(url.searchParams.get('path'), configFiles);
        assert.equal(url.searchParams.get('all'), 'true');
        return Response.json([{ ID: state === 'uncreated' ? '' : 'agenda-new-id', Name: 'agenda-agenda-1', Service: 'agenda',
          State: state === 'uncreated' ? 'uncreated' : 'running',
          Publishers: [{ TargetPort: 5173, PublishedPort: 5173, Protocol: 'tcp' }] }]);
      }
      if (url.pathname === '/v1.24/ps/unrelated') return Response.json([]);
      if (url.pathname === '/v1.24/config/unrelated') return Response.json({ services: {} });
      if (url.pathname === '/v1.24/config/agenda') return Response.json({
        services: { agenda: { ports: [{ name: 'web', target: 5173, published: '5173' }] } },
      });
      assert.equal(url.pathname, '/v1.24/start/agenda/container');
      assert.equal(request.method, 'POST');
      starts.push({ path: url.pathname, body: await request.json() });
      await new Promise<void>(resolve => { release = resolve; });
      state = 'running';
      return Response.json({ ok: true });
    } },
    RUNTIME_STATUS: { fetch: (input: string) => Promise.resolve(Response.json(input.endsWith('app-ports.json')
      ? { http: 80, https: 443 } : { phase: 'healthy', message: 'ready' })) },
  };
  const request = (host = 'agenda_agenda--p5173.app.localhost') =>
    appGateway.fetch(new Request(`https://${host}/calendar?day=today`), env, ctx);
  try {
    assert.equal((await request('agenda_agenda--p9999.app.localhost')).status, 404);
    assert.equal(starts.length, 0);
    const responses = await Promise.all([request(), request(), request('agenda_agenda--nweb.app.localhost')]);
    for (const response of responses) {
      assert.equal(response.status, 503);
      const html = await response.text();
      assert.match(html, /<h1>agenda<\/h1>/);
      assert.match(html, /Starting…/);
    }
    assert.deepEqual(starts, [{ path: '/v1.24/start/agenda/container', body: { service: 'agenda', path: configFiles } }]);
    assert.equal(requests.filter(path => path === '/v1.24/ls').length, 1);
    assert.equal(requests.filter(path => path === '/v1.24/ps/agenda').length, 1);
    assert.equal(requests.filter(path => path === '/v1.24/config/agenda').length, 1);
    release!();
    await Promise.all(background);
    assert.match(await (await request()).text(), /Starting…/, 'new container ID must retain startup tracking');
    assert.equal(requests.filter(path => path === '/v1.24/ps/agenda').length, 2, 'startup invalidates the project cache immediately');
    assert.equal(requests.filter(path => path === '/v1.24/ps/unrelated').length, 1, 'other variants remain cached');
    state = 'ready';
    const ready = await request();
    assert.equal(ready.status, 200);
    assert.equal(await ready.text(), 'agenda is ready');
    assert.equal(starts.length, 1);
  } finally {
    release?.();
    await Promise.all(background);
    Date.now = originalNow;
  }
});

Deno.test('app discovery resolves all states and detects ambiguity across config variants', async () => {
  const firstPath = '/stacks/first/compose.yaml';
  const secondPath = '/stacks/second/compose.yaml';
  const otherPath = '/stacks/other/compose.yaml';
  const requests: string[] = [];
  const env = { COMPOSE: { fetch: async (input: string) => {
    const url = new URL(input);
    requests.push(url.pathname + url.search);
    if (url.pathname === '/v1.24/ls') return Response.json([
      { Name: 'demo', ConfigFiles: `${firstPath},${secondPath}` },
      { Name: 'other', ConfigFiles: otherPath },
    ]);
    const path = url.searchParams.get('path');
    if (url.pathname.startsWith('/v1.24/config/')) return Response.json({ services: {
      web: { ports: [{ name: 'web', target: 3000, published: '8080' }] },
      web_demo: { ports: [{ target: 3000, published: '8080' }] },
    } });
    assert.equal(url.searchParams.get('all'), 'true');
    if (path === firstPath) return Response.json([
      { ID: 'first-1', Name: 'demo-web-1', Service: 'web', State: 'running',
        Publishers: [{ TargetPort: 3000, PublishedPort: 8080, Protocol: 'tcp' }] },
      { ID: 'first-2', Name: 'demo-web-2', Service: 'web', State: 'created',
        Labels: { 'com.docker.compose.container-number': '2' }, Publishers: [] },
      { ID: 'oneoff', Name: 'demo-task-run-1', Service: 'task', State: 'exited',
        Labels: { 'com.docker.compose.oneoff': 'True' } },
    ]);
    if (path === secondPath) return Response.json([
      { ID: '', Name: 'demo-web-1', Service: 'web', State: 'uncreated',
        Publishers: [{ TargetPort: 3000, PublishedPort: 8080, Protocol: 'tcp' }] },
    ]);
    assert.equal(path, otherPath);
    return Response.json([{ ID: '', Name: 'other-web_demo-1', Service: 'web_demo', State: 'uncreated' }]);
  } } };
  for (const name of ['web', 'web_demo']) {
    const ambiguous = await resolveApplicationService(name, env);
    assert(ambiguous instanceof Response);
    assert.equal(ambiguous.status, 404);
    assert.match(await ambiguous.text(), /Ambiguous service/);
  }
  const replica = await resolveApplicationService('web_demo_2', env);
  assert(!(replica instanceof Response));
  assert.equal(replica.id, 'first-2');
  assert.equal(replica.state, 'created');
  assert.equal(replica.configFiles, firstPath);
  assert.deepEqual(replica.publishedPorts, [{ target: 3000, published: 8080 }]);
  for (const name of ['task', 'missing']) {
    const missing = await resolveApplicationService(name, env);
    assert(missing instanceof Response);
    assert.equal(missing.status, 404);
    assert.equal(await missing.text(), 'Service not found');
  }
  assert.equal(requests.filter(path => path.startsWith('/v1.24/ls?')).length, 1);
  assert.equal(requests.filter(path => path.startsWith('/v1.24/ps/')).length, 3);
  assert.equal(requests.filter(path => path.startsWith('/v1.24/config/')).length, 3);
});

Deno.test('failed service discovery retries instead of caching a missing app', async () => {
  let available = false;
  let queries = 0;
  const env = { COMPOSE: { fetch: async (input: string) => {
    const url = new URL(input);
    if (url.pathname === '/v1.24/ls') return Response.json([{ Name: 'recovery', ConfigFiles: '' }]);
    if (url.pathname.startsWith('/v1.24/config/')) return Response.json({ services: { app: { ports: [] } } });
    queries++;
    return available ? Response.json([{ ID: 'recovered', Name: 'recovery-app-1', Service: 'app', State: 'running' }])
      : new Response('backend unavailable', { status: 503 });
  } } };
  await assert.rejects(() => resolveApplicationService('app_recovery', env), /discovery unavailable/);
  available = true;
  const recovered = await resolveApplicationService('app_recovery', env);
  assert(!(recovered instanceof Response));
  assert.equal(recovered.id, 'recovered');
  assert.equal(queries, 2);
});

Deno.test('Compose state reuse expires at 100 ms without being extended by slow fetches', async () => {
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  let state = 'running';
  let slow = false;
  let queries = 0;
  const env = { COMPOSE: { fetch: async (input: string) => {
    const url = new URL(input);
    if (url.pathname === '/v1.24/ls') return Response.json([{ Name: 'freshness', ConfigFiles: '' }]);
    if (url.pathname.startsWith('/v1.24/config/')) return Response.json({ services: {
      app: { ports: [{ target: 3000, published: '8080' }] },
    } });
    queries++;
    if (slow) now += 150;
    return Response.json([{ ID: 'app-1', Name: 'freshness-app-1', Service: 'app', State: state,
      Publishers: [{ TargetPort: 3000, PublishedPort: 8080, Protocol: 'tcp' }] }]);
  } } };
  const resolve = async () => {
    const service = await resolveApplicationService('app_freshness', env);
    assert(!(service instanceof Response));
    return service;
  };
  try {
    assert.equal((await resolve()).state, 'running');
    state = 'exited';
    now += 99;
    assert.equal((await resolve()).state, 'running');
    assert.equal(queries, 1, 'requests within the short reuse window share a snapshot');
    now += 1;
    assert.equal((await resolve()).state, 'exited');
    assert.equal(queries, 2, 'state refreshes at the 100 ms boundary');
    slow = true;
    now += 100;
    await resolve();
    assert.equal(queries, 3);
    state = 'running';
    assert.equal((await resolve()).state, 'running');
    assert.equal(queries, 4, 'a fetch taking longer than 100 ms is not reused after it completes');
  } finally {
    Date.now = originalNow;
  }
});

Deno.test('guest validates exact live bindings and refreshes a newly created container ID', async () => {
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  let now = originalNow() + 600_000;
  Date.now = () => now;
  const first = { Id: 'c'.repeat(64), State: 'running', Labels: {
    'com.docker.compose.project': 'validation', 'com.docker.compose.service': 'app',
  }, Ports: [{ Type: 'tcp', PrivatePort: 3000, PublicPort: 8080 }],
    NetworkSettings: { Networks: { default: { IPAddress: '172.18.0.4' } } } };
  let containers = [first];
  let reads = 0;
  const forwarded: string[] = [];
  const env = { DOCKER: { fetch: async () => { reads++; return Response.json(containers); } } };
  const request = (id = first.Id, target = 3000, published = 8080, tls = false) => router.fetch(new Request(
    tls ? 'http://localhost/__xe_tls_tunnel' : 'http://app_validation--p8080.app.localhost/deep?q=1', {
      headers: { 'x-xe-container-id': id, 'x-xe-target-port': String(target),
        'x-xe-published-port': String(published), ...(tls ? { Upgrade: 'websocket' } : {}) },
    }), env);
  globalThis.fetch = async input => {
    assert(input instanceof Request);
    assert.equal(input.headers.get('x-xe-container-id'), null);
    assert.equal(input.headers.get('x-xe-target-port'), null);
    assert.equal(input.headers.get('x-xe-published-port'), null);
    forwarded.push(input.url);
    return new Response('upstream');
  };
  try {
    assert.equal((await router.fetch(new Request('http://app.localhost/'), env)).status, 403);
    assert.equal((await request()).status, 200);
    assert.equal(forwarded[0], 'http://172.18.0.4:3000/deep?q=1');
    assert.equal((await request(first.Id, 7000)).status, 404);
    assert.equal((await request(first.Id, 3000, 9090)).status, 404);
    assert.equal((await request(first.Id, 3000, 9090, true)).status, 404);
    containers = [{ ...first, Ports: [...first.Ports, { Type: 'tcp', PrivatePort: 9000, PublicPort: 8080 }] }];
    now += 100;
    assert.equal((await request()).status, 404, 'live Docker ambiguity rejects a previously valid route');
    assert.equal((await request(first.Id, 3000, 8080, true)).status, 404, 'TLS also rejects ambiguous published ports');
    const beforeCreation = reads;
    const second = { ...first, Id: 'd'.repeat(64),
      NetworkSettings: { Networks: { default: { IPAddress: '172.18.0.5' } } } };
    containers = [second];
    assert.equal((await request(second.Id)).status, 200);
    assert.equal(reads, beforeCreation + 1, 'a new container ID refreshes Docker before the cache expires');
    assert.equal(forwarded[1], 'http://172.18.0.5:3000/deep?q=1');
    containers = [{ ...second, Ports: [{ Type: 'tcp', PrivatePort: 3000, PublicPort: 9090 }] }];
    now += 100;
    assert.equal((await request(second.Id)).status, 404, 'Docker bindings refresh after only 100 ms');
    assert.equal(forwarded.length, 2);
  } finally {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
  }
});
