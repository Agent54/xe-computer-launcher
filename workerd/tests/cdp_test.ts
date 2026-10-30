import assert from 'node:assert/strict';
import { connectCDP, handleCDP, inspectorURL } from '../cdp.js';
import { allowCDPConnection } from '../cdp-frontend.js';
import appGateway from '../app-gateway.js';

function browser() {
  const commands: Record<string, any>[] = [];
  const streams: { emit: (message: object) => void; commands: Record<string, any>[]; close: () => void }[] = [];
  const env = {
    CDP: {
      connect() {
        const index = streams.length;
        let controller: ReadableStreamDefaultController<Uint8Array>;
        let closed = false;
        const readable = new ReadableStream<Uint8Array>({ start(c) { controller = c; } });
        function emit(message: object) {
          if (!closed) controller.enqueue(new TextEncoder().encode(`${JSON.stringify(message)}\0`));
        }
        const ownCommands: Record<string, any>[] = [];
        const stream = { emit, commands: ownCommands, close() { if (!closed) { closed = true; controller.close(); } } };
        streams.push(stream);
        return {
          opened: Promise.resolve(), readable,
          writable: new WritableStream<Uint8Array>({ write(data) {
            const message = JSON.parse(new TextDecoder().decode(data).replace(/\0$/, ''));
            commands.push(message);
            ownCommands.push(message);
            let result;
            switch (message.method) {
              case 'Target.attachToBrowserTarget': result = { sessionId: `browser-${index}` }; break;
              case 'Browser.getVersion': result = { product: 'Chrome/153', protocolVersion: '1.3',
                revision: '@abcdef', userAgent: 'Test', jsVersion: '15' }; break;
              case 'Target.getTargets': result = { targetInfos: [{ targetId: 'target-1', type: 'webview',
                title: 'Controlled frame', url: 'https://example.test', parentId: 'iwa' }] }; break;
              case 'Target.attachToTarget':
                emit({ method: 'Target.attachedToTarget', sessionId: message.sessionId,
                  params: { sessionId: `page-${index}`, targetInfo: { targetId: message.params.targetId } } });
                result = { sessionId: `page-${index}` }; break;
              default: result = { value: message.params };
            }
            emit({ id: message.id, ...(message.sessionId ? { sessionId: message.sessionId } : {}), result });
          } }),
          close() { stream.close(); return Promise.resolve(); },
        };
      },
    },
    RUNTIME_STATUS: { fetch() { return Response.json({ http: 80, https: 443 }); } },
  };
  return { env, commands, streams };
}

Deno.test('discovery uses the public HTTPS origin and preserves unmodified target metadata', async () => {
  const { env, commands } = browser();
  const origin = 'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic';
  const response = await appGateway.fetch(new Request('https://compose-ui.localhost/devtools-api/json/list', {
    headers: { Origin: origin },
  }), env, {});
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), origin);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  const [target] = await response.json();
  assert.equal(target.type, 'webview');
  assert.equal(target.parentId, 'iwa');
  assert.equal(target.webSocketDebuggerUrl, 'wss://compose-ui.localhost/devtools-api/devtools/page/target-1');
  assert.equal(new URL(target.devtoolsFrontendUrl).origin, 'https://compose-ui.localhost');
  assert.equal(new URL(target.devtoolsFrontendUrl).pathname, '/devtools-api/frontend/inspector.html');
  assert.equal(new URL(target.devtoolsFrontendUrl).searchParams.get('wss'),
    'compose-ui.localhost/devtools-api/devtools/page/target-1');
  assert.equal(commands.at(-1)?.method, 'Target.detachFromTarget');
  const version = await handleCDP(new Request('https://compose-ui.localhost:5194/devtools-api/json/version'), env, {});
  assert.equal((await version.json()).webSocketDebuggerUrl,
    'wss://compose-ui.localhost:5194/devtools-api/devtools/browser');
});

Deno.test('inspector uses the packaged frontend and HTTPS port; CSP adds only the local WSS origin', () => {
  const inspector = new URL(inspectorURL(
    'wss://compose-ui.localhost:5194/devtools-api/devtools/page/page-1'));
  assert.equal(inspector.origin, 'https://compose-ui.localhost:5194');
  assert.equal(inspector.pathname, '/devtools-api/frontend/inspector.html');
  assert.equal(inspector.searchParams.get('wss'), 'compose-ui.localhost:5194/devtools-api/devtools/page/page-1');
  const policy = "default-src 'self'; script-src\n 'self' https://chrome-devtools-frontend.appspot.com; connect-src data: https://chromeuxreport.googleapis.com 'self' devtools: ws://127.0.0.1:*; object-src 'none'";
  assert.equal(allowCDPConnection(policy, inspector), policy.replace('; object-src',
    ' wss://compose-ui.localhost:5194; object-src'));
});

Deno.test('frontend serves local disk assets without query parameters or credentials', async () => {
  const { env, commands } = browser();
  const seen: Request[] = [];
  const frontendEnv = { ...env, DEVTOOLS_FRONTEND: { fetch(request: Request) {
    seen.push(request);
    return new Response('export const value = 1;', { headers: { 'Content-Type': 'text/javascript' } });
  } } };
  const response = await handleCDP(new Request(
    'https://compose-ui.localhost/devtools-api/frontend/entrypoints/inspector/inspector.js?wss=secret',
    { headers: { Cookie: 'private=secret', Authorization: 'Bearer secret', Referer: 'https://compose-ui.localhost/private' } },
  ), frontendEnv, {});
  assert.equal(response.status, 200);
  assert.equal(await response.text(), 'export const value = 1;');
  assert.equal(seen[0].url, 'http://devtools-frontend/entrypoints/inspector/inspector.js');
  assert.deepEqual([...seen[0].headers], []);
  assert.equal(response.headers.get('Content-Type'), 'text/javascript; charset=utf-8');
  assert.equal(response.headers.get('Cache-Control'), 'no-cache');
  assert.equal(commands.length, 0, 'assets do not open a browser session');
  for (const path of ['frontend/serve_rev/@abcdef/inspector.html', 'frontend/https://evil.test/inspector.html',
    'frontend/Images/', 'frontend/secret.key', 'frontend/.hidden.js', 'frontend/a//b.js',
    'frontend/third_party/.hidden/file.js', 'frontend/a%2fb.js']) {
    assert.equal((await handleCDP(new Request(`https://compose-ui.localhost/devtools-api/${path}`), frontendEnv, {})).status, 404);
  }
  assert.equal(seen.length, 1);
  const unavailable = await handleCDP(new Request(inspectorURL(
    'wss://compose-ui.localhost/devtools-api/devtools/page/page-1')), {
    ...env, DEVTOOLS_FRONTEND: { fetch() { throw new Error('offline'); } },
  }, {});
  assert.equal(unavailable.status, 502);
  const dottedDirectory = await handleCDP(new Request(
    'https://compose-ui.localhost/devtools-api/frontend/third_party/codemirror.next/codemirror.next.js',
  ), frontendEnv, {});
  assert.equal(dottedDirectory.status, 200);
  assert.equal(seen.at(-1)?.url, 'http://devtools-frontend/third_party/codemirror.next/codemirror.next.js');
  const missing = await handleCDP(new Request('https://compose-ui.localhost/devtools-api/frontend/missing.js'), {
    ...env, DEVTOOLS_FRONTEND: { fetch() { return new Response('missing', { status: 404 }); } },
  }, {});
  assert.equal(missing.status, 404);
});

Deno.test('separate browser sessions isolate events and support duplicate client command IDs', async () => {
  const { env, streams } = browser();
  const firstEvents: object[] = [];
  const secondEvents: object[] = [];
  const first = await connectCDP(env, {}, (event: object) => { firstEvents.push(event); });
  const second = await connectCDP(env, {}, (event: object) => { secondEvents.push(event); });
  try {
    const replies = await Promise.all([
      first.forward({ id: 1, method: 'Target.getTargets' }),
      second.forward({ id: 1, method: 'Target.getTargets' }),
    ]);
    assert.deepEqual(replies.map(reply => reply.id), [1, 1]);
    for (const stream of streams) {
      stream.emit({ method: 'Target.targetCreated', sessionId: 'browser-0', params: { targetInfo: { targetId: 'first' } } });
    }
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(firstEvents.length, 1);
    assert.equal(secondEvents.length, 0);
    assert(!('sessionId' in firstEvents[0]));
    const page = await first.attach('target-1');
    const reply = await first.forward({ id: 1, method: 'Runtime.evaluate', params: { expression: '1+1' }, sessionId: page });
    assert.equal(reply.sessionId, 'page-0');
    await assert.rejects(second.forward({ id: 2, method: 'Runtime.evaluate', sessionId: page }), /Invalid CDP/);
  } finally { await Promise.all([first.close(), first.close()]); await second.close(); }
});

Deno.test('browser exit rejects requests and a new connection can reconnect', async () => {
  const { env, streams } = browser();
  const connection = await connectCDP(env, {});
  streams[0].close();
  await connection.done;
  await assert.rejects(connection.forward({ id: 1, method: 'Browser.getVersion' }), /disconnected/);
  await connection.close();
  const next = await connectCDP(env, {});
  assert.equal((await next.command('Browser.getVersion')).product, 'Chrome/153');
  await next.close();
});

Deno.test('launcher API stubs stay local and retain CDP session isolation', async () => {
  const { env, commands } = browser();
  const connection = await connectCDP(env, {});
  try {
    const page = await connection.attach('target-1');
    const before = commands.length;
    const methods = [
      'Xe.showDirectoryPicker', 'Xe.getNotificationPermission',
      'Xe.requestNotificationPermission', 'Xe.showNotification',
      'Xe.closeNotification', 'Xe.setAppBadge', 'Xe.clearAppBadge',
    ];
    for (const method of methods) {
      for (const sessionId of [undefined, page]) {
        const reply = await connection.forward({ id: 42, method, params: {}, ...(sessionId ? { sessionId } : {}) });
        assert.deepEqual(reply, {
          id: 42, ...(sessionId ? { sessionId } : {}),
          error: { code: -32000, message: `${method} is not implemented`,
            data: { code: 'NOT_IMPLEMENTED', method } },
        });
      }
    }
    const unknown = await connection.forward({ id: 43, method: 'Xe.unknown' });
    assert.equal(unknown.error.code, -32601);
    assert.equal(unknown.error.data.code, 'METHOD_NOT_FOUND');
    await assert.rejects(connection.forward({ id: 44, method: methods[0], sessionId: 'another-client' }), /Invalid CDP/);
    assert.equal(commands.length, before);
    assert.equal((await connection.forward({ id: 45, method: 'Browser.getVersion' })).result.product, 'Chrome/153');
  } finally { await connection.close(); }
  await assert.rejects(connection.forward({ id: 46, method: 'Xe.showDirectoryPicker' }), /disconnected/);
});

Deno.test('CDP rejects unrelated origins, HTTP and invalid routes before connecting', async () => {
  const { env, commands } = browser();
  for (const [url, options, status] of [
    ['https://compose-ui.localhost/devtools-api/json/list', { headers: { Origin: 'https://evil.test' } }, 403],
    ['http://compose-ui.localhost/devtools-api/json/list', {}, 403],
    ['https://compose-ui.localhost/devtools-api/nope', {}, 404],
    ['https://compose-ui.localhost/devtools-api/json/list', { method: 'POST' }, 405],
  ] as const) {
    assert.equal((await handleCDP(new Request(url, options), env, {})).status, status);
  }
  assert.equal(commands.length, 0);
  const unavailable = await handleCDP(new Request('https://compose-ui.localhost/devtools-api/json/list'), {
    CDP: { connect() { throw new Error('No socket'); } },
  }, {});
  assert.equal(unavailable.status, 503);
});
