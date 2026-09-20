// Unit tests only: Docker, Compose, guest transport and upstream fetch are mocked.
import assert from 'node:assert/strict';
import gateway from '../gateway.js';
import router from '../router.js';
import { surfaceRuntimeFailure } from '../runtime-status.js';

Deno.test('management UI does not require a launcher session token', async () => {
  const env = {
    MANAGEMENT: { fetch: () => Promise.resolve(new Response('compose-ui')) },
  };
  const response = await gateway.fetch(new Request('http://127.0.0.1:8094/'), env);
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'compose-ui');
  assert.equal(response.headers.get('set-cookie'), null);
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
  phase = 'restarting';
  const runtimeFailure = await surfaceRuntimeFailure(Response.json({ error: 'backend EOF' }, { status: 500 }), env);
  assert.equal(runtimeFailure.status, 503);
  assert.equal((await runtimeFailure.json()).error, 'container_runtime_oom');
});

Deno.test('application port selection', async t => {
  const originalFetch = globalThis.fetch;
  const originalNow = Date.now;
  let now = originalNow();
  Date.now = () => now;
  const container = {
    Id: 'web-1', Labels: {
      'com.docker.compose.service': 'service', 'com.docker.compose.project': 'demo',
      'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml',
      'com.docker.compose.container-number': '1',
    },
    // Deliberately differs from YAML order; includes dual-stack duplicates and UDP.
    Ports: [
      { Type: 'tcp', PrivatePort: 3000, PublicPort: 8080 },
      { Type: 'tcp', PrivatePort: 9000, PublicPort: 9090 },
      { Type: 'tcp', PrivatePort: 9000, PublicPort: 9090 },
      { Type: 'udp', PrivatePort: 5353, PublicPort: 5353 },
      { Type: 'tcp', PrivatePort: 7000 },
    ],
    NetworkSettings: { Networks: { default: { IPAddress: '172.18.0.2' } } },
  };
  let containers = [container];
  let ports = [
    { name: 'metrics', target: 9000, published: '9090', protocol: 'tcp' },
    { name: 'web', target: 3000, published: '8080', protocol: 'tcp' },
    { name: 'dns', target: 5353, published: '5353', protocol: 'udp' },
  ];
  let configStatus = 200;
  let guestDown = false;
  const guestEnv = { DOCKER: { fetch: () => Promise.resolve(Response.json(containers)) } };
  const env = {
    ROUTER: { fetch: (input: Request | string) => {
      if (guestDown) throw new Error('Guest unavailable');
      return router.fetch(input instanceof Request ? input : new Request(input), guestEnv);
    } },
    COMPOSE: { fetch: (input: string) => {
      const url = new URL(input);
      assert.equal(url.pathname, '/v1.24/config/demo');
      assert.equal(url.searchParams.get('format'), 'json');
      assert.equal(url.searchParams.get('path'), '/stacks/demo/compose.yaml');
      return Promise.resolve(Response.json({ services: { service: { ports } } }, { status: configStatus }));
    } },
  };
  globalThis.fetch = (input: RequestInfo | URL) => {
    assert(input instanceof Request);
    return Promise.resolve(Response.json({ url: input.url, headers: Object.fromEntries(input.headers) }));
  };
  function request(host = 'service.localhost', headers?: Record<string, string>) {
    return gateway.fetch(new Request(`http://${host}:5196/hello?q=1`, { headers }), env);
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
    await t.step('caller cannot override selected ports and internal headers do not reach apps', async () => {
      const response = await request('service.web.localhost', { 'x-xe-target-port': '7000', 'x-xe-container-id': 'forged' });
      const result = await response.json();
      assert.equal(result.url, 'http://172.18.0.2:3000/hello?q=1');
      assert.equal(result.headers['x-xe-target-port'], undefined);
      assert.equal(result.headers['x-xe-container-id'], undefined);
      assert.equal(result.headers['x-forwarded-host'], 'service.web.localhost:5196');
      assert.equal((await request('localhost')).status, 403);
      assert.equal((await request('api.moby.localhost')).status, 403);
    });
    await t.step('configuration changes refresh names and default order', async () => {
      ports = [ports[1], { ...ports[0], name: 'monitor' }, ports[2]];
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
      ports = [{ ...ports[0], target: 9000, name: 'first' }, { ...ports[1], target: 3000, name: 'localhost' }];
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
      guestDown = true;
      assert.equal((await request()).status, 503);
      assert.equal((await request('service.8080.localhost')).status, 503);
    });
  } finally {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
  }
});
