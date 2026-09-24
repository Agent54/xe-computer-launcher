// Run against real workerd and pinned release assets, using disposable backends.
// Arguments: workerd [worker-directory] assets compose-binary.
// Or: --packaged workerd host-source-directory assets compose-binary guest-config.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { request as httpRequest, type IncomingMessage } from 'node:http';
import { request as httpsRequest, createServer as createHttpsServer } from 'node:https';
import { createConnection } from 'node:net';
import { once } from 'node:events';
import { resolve, dirname, join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const packaged = Deno.args[0] === '--packaged';
const inputArgs = packaged ? Deno.args.slice(1) : Deno.args;
assert(packaged ? inputArgs.length === 5 : inputArgs.length === 3 || inputArgs.length === 4,
  'Pass workerd [worker-directory] assets compose-binary, or --packaged workerd host-source-directory assets compose-binary guest-config');
const guestConfig = packaged ? resolve(inputArgs[4]) : undefined;
const args = packaged ? inputArgs.slice(0, 4) : inputArgs;
const [binary, workerDir, assets, composeBinary] = (args.length === 4 ? args :
  [args[0], dirname(dirname(fileURLToPath(import.meta.url))), args[1], args[2]]).map(p => resolve(p));
const root = await Deno.makeTempDir({ dir: '/tmp', prefix: 'xe-worker-' });
const composePath = join(root, 'compose.sock');
const dockerPath = join(root, 'docker.sock');
const routerPath = join(root, 'workerd.sock');
const statusPath = join(root, 'status');
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const processes: Deno.ChildProcess[] = [];
const outputs: Promise<Deno.CommandOutput>[] = [];
const servers = new Set<Deno.HttpServer<Deno.UnixAddr>>();
let releaseSSE: (() => void) | undefined;
const seen: { path: string; method: string; headers: IncomingMessage['headers']; body: string }[] = [];
const xeComputerOrigin = 'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic';

function startProcess(command: string, args: string[], env?: Record<string, string>) {
  const process = new Deno.Command(command, { args, env, stdout: 'piped', stderr: 'piped' }).spawn();
  processes.push(process);
  outputs.push(process.output());
  return process;
}
async function stopProcess(process: Deno.ChildProcess) {
  try { process.kill('SIGTERM'); } catch { /* already exited */ }
  const timer = setTimeout(() => { try { process.kill('SIGKILL'); } catch { /* exited */ } }, 5000);
  await process.status;
  clearTimeout(timer);
}
function freePort() {
  const listener = Deno.listen({ hostname: '127.0.0.1', port: 0 });
  const port = (listener.addr as Deno.NetAddr).port;
  listener.close();
  return port;
}
const managementPort = freePort();
let routingPort = freePort();
while (routingPort === managementPort) routingPort = freePort();
let tlsPort = freePort();
while (tlsPort === managementPort || tlsPort === routingPort) tlsPort = freePort();
const containerId = 'a'.repeat(64);
let securePort = 0;

interface Options { method?: string; body?: string; headers?: Record<string, string>; host?: string; app?: boolean }
function response(path = '/', options: Options = {}): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    let host = options.host || '127.0.0.1:8094';
    if (options.app && !host.includes(':')) host += `:${routingPort}`;
    const req = httpRequest({ hostname: '127.0.0.1', port: options.app ? routingPort : managementPort,
      path, method: options.method || 'GET', agent: false,
      headers: { Host: host, ...options.headers },
    }, resolve);
    req.on('error', reject);
    req.setTimeout(3000, () => req.destroy(new Error(`Request timed out: ${path}`)));
    req.end(options.body);
  });
}
async function request(path = '/', options: Options = {}) {
  const res = await response(path, options);
  const chunks: Uint8Array[] = [];
  for await (const chunk of res) chunks.push(chunk);
  return { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) };
}
async function startUnix(path: string) {
  try { await Deno.remove(path); } catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; }
  const server = Deno.serve({ path, onListen() {} }, async req => {
    const body = await req.text();
    const url = new URL(req.url);
    const requestPath = url.pathname + url.search;
    seen.push({ path: requestPath, method: req.method, headers: Object.fromEntries(req.headers), body });
    const headers = { 'Connection': 'close', 'Content-Type': 'application/json' };
    if (requestPath === '/v1.24/config/demo?format=json') {
      return Response.json({ services: { web: { ports: [
        { name: 'web', target: appPort, published: '32000', protocol: 'tcp' },
        { name: 'secure', target: securePort, published: '32001', protocol: 'tcp', app_protocol: 'https' },
      ] } } });
    } else if (requestPath === '/v1.24/failure') {
      return Response.json({ error: 'backend EOF' }, { status: 500 });
    } else if (requestPath === '/containers/json') {
      return new Response(JSON.stringify([{ Id: containerId, Labels: {
        'com.docker.compose.service': 'web', 'com.docker.compose.project': 'demo',
      }, Ports: [
        { Type: 'tcp', PrivatePort: appPort, PublicPort: 32000 },
        { Type: 'tcp', PrivatePort: securePort, PublicPort: 32001 },
      ],
        NetworkSettings: { Networks: { test: { IPAddress: '127.0.0.1' } } } }]), { headers });
    } else if (requestPath === '/v1.24/events') {
      const stream = new ReadableStream({ start(controller) {
        controller.enqueue(new TextEncoder().encode('data: first\n\n'));
        releaseSSE = () => { controller.close(); releaseSSE = undefined; };
      }, cancel() { releaseSSE = undefined; } });
      return new Response(stream, { headers: { ...headers, 'Content-Type': 'text/event-stream' } });
    } else {
      return new Response(body || 'upstream-ok', { headers });
    }
  });
  servers.add(server);
  return server;
}
async function stopUnix(server: Deno.HttpServer<Deno.UnixAddr>, path: string) {
  await server.shutdown();
  servers.delete(server);
  try { await Deno.remove(path); } catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; }
}
async function* files(directory: string): AsyncGenerator<string> {
  for await (const entry of Deno.readDir(directory)) {
    const path = join(directory, entry.name);
    if (entry.isDirectory) yield* files(path);
    else if (entry.isFile) yield path;
  }
}

const app = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen() {} }, req => {
  const url = new URL(req.url);
  if (req.headers.get('upgrade') === 'websocket') {
    const { socket, response } = Deno.upgradeWebSocket(req);
    socket.onmessage = event => socket.send(event.data);
    return response;
  }
  seen.push({ path: url.pathname + url.search, method: req.method, headers: {}, body: '' });
  return url.pathname === '/redirect'
    ? new Response(null, { status: 302, headers: { Location: 'http://127.0.0.1:8094/v1.24/private' } })
    : new Response('upstream-ok');
});
const appPort = app.addr.port;

async function tlsRequest(hostname: string): Promise<{ status: number; body: string }> {
  return await new Promise((resolve, reject) => {
    const request = httpsRequest({ hostname: '127.0.0.1', port: tlsPort, servername: hostname,
      rejectUnauthorized: false, headers: { Host: hostname }, timeout: 5000 }, response => {
      const chunks: Uint8Array[] = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode || 0,
        body: Buffer.concat(chunks).toString() }));
      response.on('error', reject);
    });
    request.on('error', reject);
    request.on('timeout', () => request.destroy(new Error('TLS request timed out')));
    request.end();
  });
}

async function verifyWebSocket() {
  // A raw handshake lets the test keep production Host validation on an ephemeral port.
  const socket = createConnection({ host: '127.0.0.1', port: routingPort });
  try {
    await once(socket, 'connect');
    socket.setTimeout(3000, () => socket.destroy(new Error('WebSocket echo timed out')));
    socket.write('GET /ws HTTP/1.1\r\nHost: web.localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n');
    let buffered = Buffer.alloc(0);
    let upgraded = false;
    for await (const chunk of socket) {
      buffered = Buffer.concat([buffered, chunk]);
      if (!upgraded) {
        const end = buffered.indexOf('\r\n\r\n');
        if (end < 0) continue;
        const headers = buffered.subarray(0, end).toString();
        assert.match(headers, /^HTTP\/1\.1 101 /);
        assert.match(headers, /s3pPLMBiTxaQ9kYGzzhZRbK\+xOo=/);
        buffered = buffered.subarray(end + 4);
        upgraded = true;
        // Masked client text frame, payload "ping".
        socket.write(Buffer.from([0x81, 0x84, 1, 2, 3, 4, 0x70 ^ 1, 0x69 ^ 2, 0x6e ^ 3, 0x67 ^ 4]));
      }
      if (buffered.length >= 6) {
        assert.equal(buffered[0], 0x81);
        assert.equal(buffered[1], 4);
        assert.equal(buffered.subarray(2, 6).toString(), 'ping');
        return;
      }
    }
    assert.fail('WebSocket closed before echo');
  } finally { socket.destroy(); }
}

try {
  const certificate = join(root, 'test.crt');
  const privateKey = join(root, 'test.key');
  const generated = await new Deno.Command('openssl', { args: [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-keyout', privateKey, '-out', certificate, '-subj', '/CN=web.secure.localhost',
    '-addext', 'subjectAltName=DNS:web.secure.localhost',
  ], stdout: 'null', stderr: 'piped' }).output();
  assert.equal(generated.code, 0, new TextDecoder().decode(generated.stderr));
  const uiCertificate = join(root, 'ui.crt');
  const uiPrivateKey = join(root, 'ui.key');
  const uiGenerated = await new Deno.Command('openssl', { args: [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-keyout', uiPrivateKey, '-out', uiCertificate, '-subj', '/CN=compose-ui.localhost',
    '-addext', 'subjectAltName=DNS:compose-ui.localhost,DNS:*.app.localhost',
  ], stdout: 'null', stderr: 'piped' }).output();
  assert.equal(uiGenerated.code, 0, new TextDecoder().decode(uiGenerated.stderr));
  const tlsApp = createHttpsServer({ key: await Deno.readTextFile(privateKey),
    cert: await Deno.readTextFile(certificate) }, (_request, response) => response.end('tls-upstream-ok'));
  await new Promise<void>(resolve => tlsApp.listen(0, '127.0.0.1', resolve));
  securePort = (tlsApp.address() as { port: number }).port;
  try {
  await Deno.mkdir(statusPath);
  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'healthy', message: 'Container runtime ready', reason: null,
  }));
  await Deno.writeTextFile(join(statusPath, 'app-ports.json'), JSON.stringify({
    http: routingPort, https: tlsPort,
  }));
  // Run the packaged sources with generated TLS files, as the launcher does.
  for await (const entry of Deno.readDir(workerDir)) {
    if (entry.isFile && (entry.name.endsWith('.js') || entry.name === 'config.capnp')) {
      await Deno.copyFile(join(workerDir, entry.name), join(root, entry.name));
    }
  }
  const configPath = join(root, 'config.capnp');
  const uiSocketPath = join(root, 'ui-https.sock');
  startProcess(binary, ['serve', '--experimental', configPath,
    '--socket-addr', `management=127.0.0.1:${managementPort}`, '--socket-addr', `ingest=127.0.0.1:${routingPort}`,
    '--socket-addr', `tls=127.0.0.1:${tlsPort}`,
    '--socket-addr', `ui-https=unix:${uiSocketPath}`,
    '--directory-path', `assets=${assets}`,
    '--directory-path', `status=${statusPath}`,
    '--external-addr', `compose=unix:${composePath}`, '--external-addr', `router=unix:${routerPath}`,
    '--external-addr', `ui-tls=unix:${uiSocketPath}`]);
  const guestPath = packaged ? join(root, 'guest-worker.bin') : join(workerDir, 'docker/config.capnp');
  if (packaged) await Deno.copyFile(guestConfig!, guestPath);
  const startRouter = () => startProcess(binary, ['serve', '--experimental', ...(packaged ? ['--binary'] : []), guestPath,
    '--socket-addr', `router=unix:${routerPath}`, '--external-addr', `docker=unix:${dockerPath}`]);
  let ready = false;
  for (let i = 0; i < 80; i++) {
    try { if ((await request()).status === 200) { ready = true; break; } } catch { /* starting */ }
    await sleep(100);
  }
  assert(ready, 'workerd failed to become ready');
  const html = await request();
  assert.deepEqual(html.body, Buffer.from(await Deno.readFile(join(assets, 'index.html'))));
  assert.match(String(html.headers['content-type']), /^text\/html/);
  assert.equal(html.headers['x-frame-options'], 'DENY');
  const browserNavigation = await request('/', { headers: { 'Sec-Fetch-Mode': 'navigate' } });
  assert.equal(browserNavigation.status, 307);
  assert.equal(browserNavigation.headers.location, `http://compose-ui.localhost:${routingPort}/`);
  assert.equal(browserNavigation.headers['cache-control'], 'no-store');
  assert.equal((await request('/', { host: 'app_flux.localhost:8094' })).status, 403);
  const appUI = await request('/', { app: true, host: 'compose-ui.localhost' });
  assert.equal(appUI.status, 200);
  assert.deepEqual(appUI.body, html.body);
  assert.equal((await request('/', { app: true, host: 'compose-ui.localhost',
    headers: { Origin: 'https://evil.test' } })).status, 403);
  const deniedRequests: Options[] = [{ headers: { Origin: 'https://evil.test' } }, { headers: { Origin: 'http://web.localhost' } },
    { headers: { 'Sec-Fetch-Site': 'cross-site' } }, { host: 'evil.test:8094' }];
  for (const options of deniedRequests) {
    assert.equal((await request('/', options)).status, 403);
  }
  const composeUIUnavailable = await request('/v1.24/ls', { headers: {
    Origin: xeComputerOrigin, 'Sec-Fetch-Site': 'cross-site',
  } });
  assert.equal(composeUIUnavailable.status, 503);
  assert.equal(composeUIUnavailable.headers['access-control-allow-origin'], xeComputerOrigin);
  const checkoutPreflight = await request('/v1.24/repos/checkout', { method: 'OPTIONS', headers: {
    Origin: xeComputerOrigin,
    'Sec-Fetch-Site': 'cross-site',
    'Access-Control-Request-Method': 'POST',
    'Access-Control-Request-Headers': 'content-type',
    'Access-Control-Request-Private-Network': 'true',
  } });
  assert.equal(checkoutPreflight.status, 204);
  assert.equal(checkoutPreflight.headers['access-control-allow-origin'], xeComputerOrigin);
  assert.equal(checkoutPreflight.headers['access-control-allow-methods'], 'POST');
  assert.equal(checkoutPreflight.headers['access-control-allow-private-network'], 'true');
  assert.equal((await request('/v1.24/ls', { app: true, host: 'api.moby.localhost' })).status, 403);
  assert.equal(JSON.parse((await request('/v1.24/runtime-status')).body.toString()).phase, 'healthy');
  assert.equal((await request('/v1.24/ls')).status, 503);
  for (const path of ['/api/unknown', '/_app/immutable/missing.js', '/_app/']) {
    assert.equal((await request(path)).status, 404, path);
  }
  assert.equal((await request('/', { method: 'POST', body: '' })).status, 405);
  for await (const file of files(assets)) {
    if (!['.js', '.css', '.svg', '.json', '.txt', '.html'].includes(extname(file))) continue;
    const path = file.slice(assets.length);
    const result = await request(path);
    assert.equal(result.status, 200, path);
    if (path !== '/index.html') assert.deepEqual(result.body, Buffer.from(await Deno.readFile(file)), path);
    if (extname(file) === '.js') assert.match(String(result.headers['content-type']), /^text\/javascript/);
    if (path.includes('/immutable/')) assert.match(String(result.headers['cache-control']), /immutable/);
  }
  console.log('PASS: source UI assets, shared-port UI hostname, and UI without Docker/Compose');
  assert.equal((await request('/', { app: true, host: 'web.localhost' })).status, 503);
  let guest = startRouter();
  await sleep(500);

  let compose = await startUnix(composePath);
  let docker = await startUnix(dockerPath);
  const payload = '{"test":true}';
  const checkoutPayload = '{"url":"https://github.com/Agent54/darc-code","path":"development"}';
  const checkout = await request('/v1.24/repos/checkout', { method: 'POST', body: checkoutPayload, headers: {
    Origin: xeComputerOrigin,
    'Sec-Fetch-Site': 'cross-site',
    'Content-Type': 'application/json',
  } });
  assert.equal(checkout.status, 200);
  assert.equal(checkout.body.toString(), checkoutPayload);
  assert.equal(checkout.headers['access-control-allow-origin'], xeComputerOrigin);
  assert.equal(seen.at(-1)!.path, '/v1.24/repos/checkout');
  assert.equal(seen.at(-1)!.method, 'POST');
  assert.equal((await request('/v1.24/up?project=test', { method: 'POST', body: payload,
    headers: { Origin: 'http://127.0.0.1:8094', Authorization: 'secret', Cookie: 'iwa_session=secret', 'Content-Type': 'application/json' } })).body.toString(), payload);
  assert.equal(seen.at(-1)!.path, '/v1.24/up?project=test');
  assert.equal(seen.at(-1)!.method, 'POST');
  assert.equal(seen.at(-1)!.headers.cookie, undefined);
  assert.equal(seen.at(-1)!.headers.authorization, undefined);
  const healthyFailure = await request('/v1.24/failure');
  assert.equal(healthyFailure.status, 500);
  assert.equal(JSON.parse(healthyFailure.body.toString()).error, 'backend EOF');
  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'restarting', message: 'Container VM ran out of memory; restarting…', reason: 'oom',
  }));
  const unavailable = await request('/v1.24/failure');
  assert.equal(unavailable.status, 503);
  assert.equal(JSON.parse(unavailable.body.toString()).error, 'container_runtime_oom');
  assert.match(JSON.parse(unavailable.body.toString()).message, /ran out of memory/);
  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'healthy', message: 'Container runtime ready', reason: null,
  }));
  const sse = await response('/v1.24/events');
  assert.equal(sse.headers['content-type'], 'text/event-stream');
  const [first] = await once(sse, 'data');
  assert.equal(first.toString(), 'data: first\n\n', 'SSE must arrive before backend EOF');
  const sseEnded = once(sse, 'end');
  releaseSSE!();
  sse.resume();
  await sseEnded;
  const appOptions = { app: true, host: 'web.localhost' };
  assert.equal((await request('/hello?q=1', appOptions)).body.toString(), 'upstream-ok');
  assert.equal(seen.at(-1)!.path, '/hello?q=1');
  assert.equal((await request('/redirect', appOptions)).status, 302);
  assert.equal((await request('/', { app: true, host: 'web.32000.localhost' })).status, 200);
  assert.equal((await request('/', { app: true, host: 'web.web.localhost' })).status, 200);
  assert.equal((await request('/', { app: true, host: 'web.1.localhost' })).status, 404);
  assert.equal((await request('/', { app: true, host: 'missing.localhost' })).status, 404);
  const secureRedirect = await request('/', { app: true, host: 'web.secure.localhost' });
  assert.equal(secureRedirect.status, 307);
  assert.equal(secureRedirect.headers.location, `https://web.secure.localhost:${tlsPort}/`);
  assert.deepEqual(await tlsRequest('web.secure.localhost'), { status: 200, body: 'tls-upstream-ok' });
  await verifyWebSocket();
  console.log('PASS: Compose forwarding, SSE, guest private-port routing over Unix socket, WebSocket echo, and redirects');

  await stopProcess(guest);
  assert.equal((await request('/', appOptions)).status, 503);
  assert.equal((await request()).status, 200);
  try { await Deno.remove(routerPath); } catch (error) { if (!(error instanceof Deno.errors.NotFound)) throw error; }
  guest = startRouter();
  await sleep(500);
  assert.equal((await request('/', appOptions)).status, 200);

  await stopUnix(compose, composePath);
  await stopUnix(docker, dockerPath);
  await sleep(2100);
  assert.equal((await request('/v1.24/ls')).status, 503);
  assert.equal((await request('/', appOptions)).status, 503);
  assert.equal((await request()).status, 200);
  compose = await startUnix(composePath);
  docker = await startUnix(dockerPath);
  assert.equal((await request('/v1.24/ls')).status, 200);
  assert.equal((await request('/', appOptions)).status, 200);
  console.log('PASS: backend socket replacement and recovery without restarting workerd');

  await stopUnix(compose, composePath);
  const realCompose = startProcess(composeBinary, ['serve', root], { DOCKER_HOST: `unix:${root}/absent.sock`, DOCKER_CONTEXT: '' });
  let composeReady = false;
  for (let i = 0; i < 60; i++) {
    if ((await request('/v1.24/_ping')).status === 200) { composeReady = true; break; }
    await sleep(100);
  }
  assert(composeReady, 'Real Compose API did not start without Docker');
  assert.equal((await request()).status, 200);
  await stopProcess(realCompose);
  console.log('PASS: actual Compose fork serves its API without Docker');
} catch (error) {
  for (const process of processes) await stopProcess(process);
  for (const output of outputs) console.error(new TextDecoder().decode((await output).stderr));
  throw error;
  } finally { tlsApp.close(); }
} finally {
  releaseSSE?.();
  for (const process of processes) await stopProcess(process);
  for (const server of servers) await server.shutdown();
  await app.shutdown();
  await Deno.remove(root, { recursive: true });
}
