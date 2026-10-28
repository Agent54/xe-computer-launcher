// Run against real workerd and pinned release assets, using disposable backends.
// Arguments: workerd [worker-directory] assets compose-binary.
// Or: --packaged workerd host-source-directory assets compose-binary guest-config.
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { request as httpRequest, type IncomingMessage } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { createConnection } from 'node:net';
import { connect as connectTLS } from 'node:tls';
import { once } from 'node:events';
import { gzipSync } from 'node:zlib';
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
const root = await Deno.makeTempDir({ dir: resolve(dirname(fileURLToPath(import.meta.url)), '../../macos/.build'), prefix: 'xe-worker-' });
const composePath = join(root, 'compose.sock');
const dockerPath = join(root, 'docker.sock');
const routerPath = join(root, 'workerd.sock');
const cdpPath = join(root, 'cdp.sock');
const statusPath = join(root, 'status');
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));
const processes: Deno.ChildProcess[] = [];
const outputs: Promise<Deno.CommandOutput>[] = [];
const servers = new Set<Deno.HttpServer<Deno.UnixAddr>>();
let releaseSSE: (() => void) | undefined;
const seen: { path: string; method: string; headers: IncomingMessage['headers']; body: string }[] = [];
const xeComputerOrigin = 'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic';
const browserCommands: Record<string, any>[] = [];
const cdpClients = new Set<Deno.UnixConn>();
let cdpListener: Deno.UnixListener | undefined;

async function mockBrowser(connection: Deno.UnixConn) {
  cdpClients.add(connection);
  const sessionId = crypto.randomUUID();
  let buffered = '';
  const decoder = new TextDecoder();
  const buffer = new Uint8Array(65536);
  try {
    while (true) {
      const count = await connection.read(buffer);
      if (count === null) return;
      buffered += decoder.decode(buffer.subarray(0, count), { stream: true });
      let delimiter;
      while ((delimiter = buffered.indexOf('\0')) !== -1) {
        const message = JSON.parse(buffered.slice(0, delimiter));
        buffered = buffered.slice(delimiter + 1);
        browserCommands.push(message);
        let result;
        switch (message.method) {
          case 'Target.attachToBrowserTarget': result = { sessionId }; break;
          case 'Browser.getVersion': result = { product: 'Helium/153', protocolVersion: '1.3', revision: '@abcdef' }; break;
          case 'Target.getTargets': result = { targetInfos: [{ targetId: 'controlled-frame', type: 'webview',
            title: 'Controlled frame', url: 'https://example.test', parentId: 'iwa' }] }; break;
          case 'Target.attachToTarget': result = { sessionId: `${sessionId}-page` }; break;
          case 'Runtime.evaluate': result = { result: { type: 'number', value: 2 } }; break;
          default: result = {};
        }
        const reply = new TextEncoder().encode(`${JSON.stringify({ id: message.id, result,
          ...(message.sessionId ? { sessionId: message.sessionId } : {}),
        })}\0`);
        let sent = 0;
        while (sent < reply.length) sent += await connection.write(reply.subarray(sent));
      }
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.BadResource || error instanceof Deno.errors.BrokenPipe ||
          error instanceof Deno.errors.ConnectionReset)) throw error;
  } finally { cdpClients.delete(connection); try { connection.close(); } catch { /* closed */ } }
}

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
const sleepingId = 'b'.repeat(64);
let sleepingState = 'uncreated';
let releaseContainerStart: (() => void) | undefined;
let securePort = 0;
let discoveryEntered: (() => void) | undefined;
let releaseDiscovery: (() => void) | undefined;

interface Options { method?: string; body?: string; headers?: Record<string, string>; host?: string; app?: boolean; timeoutMs?: number }
function response(path = '/', options: Options = {}): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    let host = options.host || '127.0.0.1:8094';
    if (options.app && !host.includes(':')) host += `:${routingPort}`;
    const req = httpRequest({ hostname: '127.0.0.1', port: options.app ? routingPort : managementPort,
      path, method: options.method || 'GET', agent: false,
      headers: { Host: host, ...options.headers },
    }, resolve);
    req.on('error', reject);
    req.setTimeout(options.timeoutMs ?? 3000, () => req.destroy(new Error(`Request timed out: ${path}`)));
    req.end(options.body);
  });
}
async function request(path = '/', options: Options = {}) {
  try {
    const res = await response(path, options);
    const chunks: Uint8Array[] = [];
    for await (const chunk of res) chunks.push(chunk);
    return { status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) };
  } catch (cause) {
    throw new Error(`Request failed: ${options.method || 'GET'} ${options.host || 'management'}${path}`, { cause });
  }
}
async function startUnix(path: string) {
  try { await Deno.remove(path); } catch (e) { if (!(e instanceof Deno.errors.NotFound)) throw e; }
  const server = Deno.serve({ path, onListen() {} }, async req => {
    const body = await req.text();
    const url = new URL(req.url);
    const requestPath = url.pathname + url.search;
    seen.push({ path: requestPath, method: req.method, headers: Object.fromEntries(req.headers), body });
    const headers = { 'Connection': 'close', 'Content-Type': 'application/json' };
    if (url.pathname === '/v1.24/config/demo' && url.searchParams.get('format') === 'json') {
      if (url.searchParams.get('path') === '/stacks/other/compose.yaml') return Response.json({ services: {} });
      return Response.json({ services: { web: { ports: [
        { name: 'web', target: appPort, published: '32000', protocol: 'tcp' },
        { name: 'secure', target: securePort, published: '32001', protocol: 'tcp', app_protocol: 'https' },
      ] }, sleeping: { ports: [{ name: 'web', target: appPort, protocol: 'tcp' }] } } });
    } else if (requestPath === '/v1.24/ls?all=true') {
      if (discoveryEntered) {
        const entered = discoveryEntered;
        discoveryEntered = undefined;
        await new Promise<void>(resolve => { releaseDiscovery = resolve; entered(); });
      }
      return Response.json([{ Name: 'demo', ConfigFiles: '/stacks/other/compose.yaml,/stacks/demo/compose.yaml' }]);
    } else if (url.pathname === '/v1.24/ps/demo') {
      if (url.searchParams.get('path') === '/stacks/other/compose.yaml') return Response.json([{
        ID: containerId, Service: 'web', State: 'running',
        Labels: { 'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml' },
      }]);
      return Response.json([{
        ID: containerId, Name: 'demo-web-1', Service: 'web', State: 'running',
        Labels: { 'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml' },
        Publishers: [
          { TargetPort: appPort, PublishedPort: 32000, Protocol: 'tcp' },
          { TargetPort: securePort, PublishedPort: 32001, Protocol: 'tcp' },
        ],
      }, {
        ID: sleepingState === 'uncreated' ? '' : sleepingId,
        Name: 'demo-sleeping-1', Service: 'sleeping', State: sleepingState,
        Labels: { 'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml' },
        Publishers: sleepingState === 'running' ? [{ TargetPort: appPort, PublishedPort: 32002, Protocol: 'tcp' }] : [],
      }]);
    } else if (requestPath === '/v1.24/failure') {
      return Response.json({ error: 'backend EOF' }, { status: 500 });
    } else if (requestPath === '/v1.24/start/demo/container' && req.method === 'POST') {
      assert.deepEqual(JSON.parse(body), { service: 'sleeping', path: '/stacks/demo/compose.yaml' });
      await new Promise<void>(resolve => { releaseContainerStart = resolve; });
      sleepingState = 'running';
      return Response.json({ ok: true });
    } else if (requestPath === `/containers/${sleepingId}/json`) {
      return Response.json({ HostConfig: { PortBindings: { [`${appPort}/tcp`]: [{ HostPort: '32002' }] } } });
    } else if (requestPath === '/images/json?all=true') {
      return Response.json([{ Id: 'image', Size: 4096 }]);
    } else if (requestPath === '/volumes') {
      return Response.json({ Volumes: [{ Name: 'old-db', Driver: 'local' }] });
    } else if (requestPath === '/system/df') {
      return Response.json({ LayersSize: 4096, Images: [{ Id: 'image', Size: 4096, SharedSize: 0, Containers: 0 }] });
    } else if (requestPath === '/containers/json?all=true' || requestPath === '/containers/json?all=true&size=false') {
      return new Response(JSON.stringify([{ Id: containerId, State: 'running', Labels: {
        'com.docker.compose.service': 'web', 'com.docker.compose.project': 'demo',
      }, Ports: [
        { Type: 'tcp', PrivatePort: appPort, PublicPort: 32000 },
        { Type: 'tcp', PrivatePort: securePort, PublicPort: 32001 },
      ],
        NetworkSettings: { Networks: { test: { IPAddress: '127.0.0.1' } } } },
        ...(sleepingState === 'uncreated' ? [] : [{ Id: sleepingId, State: sleepingState, Labels: {
          'com.docker.compose.service': 'sleeping', 'com.docker.compose.project': 'demo',
          'com.docker.compose.project.config_files': '/stacks/demo/compose.yaml',
        }, Ports: sleepingState === 'running' ? [{ Type: 'tcp', PrivatePort: appPort, PublicPort: 32002 }] : [],
        NetworkSettings: { Networks: { test: { IPAddress: '127.0.0.1' } } } }]),
      ]), { headers });
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

async function tlsRequest(hostname: string, publicPort = false, path = '/', origin?: string) {
  const { status, body } = await tlsResponse(hostname, publicPort, path, origin);
  return { status, body };
}

async function tlsResponse(hostname: string, publicPort = false, path = '/', origin?: string): Promise<{ status: number; body: string; headers: Headers }> {
  // Use the URL hostname for TLS SNI as well as HTTP Host. Deno's node:https
  // compatibility client can omit SNI when connecting to a loopback IP.
  const result = await new Deno.Command('curl', { args: [
    '--disable', '--noproxy', '*', '--silent', '--show-error', '--insecure', '--max-time', '5', '--include',
    '--resolve', `${hostname}:${tlsPort}:127.0.0.1`,
    '--header', `Host: ${publicPort ? `${hostname}:${tlsPort}` : hostname}`,
    ...(origin ? ['--header', `Origin: ${origin}`] : []),
    '--write-out', '\n%{http_code}', `https://${hostname}:${tlsPort}${path}`,
  ], stdout: 'piped', stderr: 'piped' }).output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
  const output = new TextDecoder().decode(result.stdout);
  const separator = output.lastIndexOf('\n');
  const headerEnd = output.indexOf('\r\n\r\n');
  assert(headerEnd >= 0, 'HTTPS response headers are missing');
  const headers = new Headers();
  for (const line of output.slice(0, headerEnd).split('\r\n').slice(1)) {
    const colon = line.indexOf(':');
    headers.append(line.slice(0, colon), line.slice(colon + 1).trim());
  }
  return { status: Number(output.slice(separator + 1)), body: output.slice(headerEnd + 4, separator), headers };
}

async function verifyCDPWebSocket(path: string) {
  const socket = connectTLS({ host: '127.0.0.1', port: tlsPort,
    servername: 'compose-ui.localhost', rejectUnauthorized: false });
  try {
    await once(socket, 'secureConnect');
    socket.setTimeout(5000, () => socket.destroy(new Error('CDP connection timed out')));
    socket.write(`GET ${path} HTTP/1.1\r\nHost: compose-ui.localhost:${tlsPort}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nOrigin: ${xeComputerOrigin}\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    let buffered = Buffer.alloc(0);
    let upgraded = false;
    for await (const chunk of socket) {
      buffered = Buffer.concat([buffered, chunk]);
      if (!upgraded) {
        const end = buffered.indexOf('\r\n\r\n');
        if (end < 0) continue;
        assert.match(buffered.subarray(0, end).toString(), /^HTTP\/1\.1 101 /);
        buffered = buffered.subarray(end + 4);
        upgraded = true;
        const payload = Buffer.from(JSON.stringify({ id: 7, method: 'Runtime.evaluate', params: { expression: '1+1' } }));
        const mask = Buffer.from([1, 2, 3, 4]);
        const frame = Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask,
          Buffer.from(payload.map((value, index) => value ^ mask[index % 4]))]);
        socket.write(frame);
      }
      if (buffered.length < 2) continue;
      const length = buffered[1] & 0x7f;
      assert(length < 126, 'Small fixture response expected');
      if (buffered.length < length + 2) continue;
      assert.equal(buffered[0], 0x81);
      const message = JSON.parse(buffered.subarray(2, length + 2).toString());
      assert.equal(message.id, 7);
      assert.equal(message.result.result.value, 2);
      assert.equal(message.sessionId, undefined, 'The synthetic root session stays private');
      return;
    }
    assert.fail('CDP connection closed without a response');
  } finally { socket.destroy(); }
}

async function verifyWebSocket() {
  // A raw handshake lets the test keep production Host validation on an ephemeral port.
  const socket = createConnection({ host: '127.0.0.1', port: routingPort });
  try {
    await once(socket, 'connect');
    socket.setTimeout(3000, () => socket.destroy(new Error('WebSocket echo timed out')));
    socket.write(`GET /ws HTTP/1.1\r\nHost: web.localhost:${routingPort}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n`);
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
  cdpListener = Deno.listen({ transport: 'unix', path: cdpPath });
  const listener = cdpListener;
  (async () => {
    try { for await (const connection of listener) await mockBrowser(connection); }
    catch (error) { if (!(error instanceof Deno.errors.BadResource)) throw error; }
  })();
  const certificate = join(root, 'test.crt');
  const privateKey = join(root, 'test.key');
  const generated = await new Deno.Command('openssl', { args: [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-keyout', privateKey, '-out', certificate, '-subj', '/CN=web.secure.localhost',
    '-addext', 'subjectAltName=DNS:web.secure.localhost,DNS:chrome-devtools-frontend.appspot.com',
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
  const frontendRequests: string[] = [];
  const frontendPolicy = "default-src 'self' devtools: data:; script-src 'self'; connect-src data: https://chromeuxreport.googleapis.com 'self' devtools: ws://127.0.0.1:*; object-src 'none';";
  const tlsApp = createHttpsServer({ key: await Deno.readTextFile(privateKey),
    cert: await Deno.readTextFile(certificate) }, (request, response) => {
      if (request.headers.host !== 'chrome-devtools-frontend.appspot.com') return response.end('tls-upstream-ok');
      frontendRequests.push(request.url!);
      response.setHeader('Cache-Control', 'public, max-age=604800');
      if (request.url === '/serve_rev/@abcdef/inspector.html') {
        response.setHeader('Content-Type', 'text/html');
        response.setHeader('Content-Encoding', 'gzip');
        response.setHeader('Content-Security-Policy', frontendPolicy);
        response.end(gzipSync(`<html><meta\n http-equiv="Content-Security-Policy"\n content="${frontendPolicy}"><script type="module" src="./entrypoints/inspector/inspector.js"></script></html>`));
      } else if (request.url === '/serve_rev/@abcdef/entrypoints/inspector/inspector.js') {
        response.setHeader('Content-Type', 'text/javascript');
        response.setHeader('Content-Encoding', 'gzip');
        response.end(gzipSync('export const inspector = true;'));
      } else {
        response.writeHead(404);
        response.end('missing');
      }
    });
  await new Promise<void>(resolve => tlsApp.listen(0, '127.0.0.1', resolve));
  securePort = (tlsApp.address() as { port: number }).port;
  try {
  await Deno.mkdir(statusPath);
  const startupStatePath = join(root, 'startup-state');
  await Deno.mkdir(startupStatePath);
  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'healthy', bootId: 'integration-boot', message: 'Container runtime ready', reason: null,
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
  await Deno.writeTextFile(configPath, (await Deno.readTextFile(configPath)).replace(
    'trustBrowserCas = true', 'trustBrowserCas = true, trustedCertificates = [embed "test.crt"]'));
  const uiSocketPath = join(root, 'ui-https.sock');
  startProcess(binary, ['serve', '--experimental', configPath,
    '--socket-addr', `management=127.0.0.1:${managementPort}`, '--socket-addr', `ingest=127.0.0.1:${routingPort}`,
    '--socket-addr', `tls=127.0.0.1:${tlsPort}`,
    '--socket-addr', `ui-https=unix:${uiSocketPath}`,
    '--socket-addr', `startup=unix:${join(root, 'startup.sock')}`,
    '--directory-path', `assets=${assets}`,
    '--directory-path', `status=${statusPath}`,
    '--directory-path', `startup-state=${startupStatePath}`,
    '--external-addr', `compose=unix:${composePath}`, '--external-addr', `router=unix:${routerPath}`,
    '--external-addr', `docker=unix:${dockerPath}`,
    '--external-addr', `maintenance=unix:${join(root, 'maintenance.sock')}`,
    '--external-addr', `cdp=unix:${cdpPath}`,
    '--external-addr', `devtools-frontend=127.0.0.1:${securePort}`,
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
  const cdpList = await tlsRequest('compose-ui.localhost', true, '/devtools-api/json/list', xeComputerOrigin);
  assert.equal(cdpList.status, 200, cdpList.body);
  const [cdpTarget] = JSON.parse(cdpList.body);
  assert.equal(cdpTarget.type, 'webview', 'IWA rewriting is intentionally a no-op for now');
  assert.equal(cdpTarget.parentId, 'iwa');
  assert.equal(cdpTarget.webSocketDebuggerUrl,
    `wss://compose-ui.localhost:${tlsPort}/devtools-api/devtools/page/controlled-frame`);
  const inspector = new URL(cdpTarget.devtoolsFrontendUrl);
  assert.equal(inspector.origin, `https://compose-ui.localhost:${tlsPort}`);
  assert.equal(inspector.pathname, '/devtools-api/frontend/serve_rev/@abcdef/inspector.html');
  const frontend = await tlsResponse('compose-ui.localhost', true, inspector.pathname + inspector.search);
  assert.equal(frontend.status, 200, frontend.body);
  const expectedPolicy = frontendPolicy.replace('; object-src', ` wss://compose-ui.localhost:${tlsPort}; object-src`);
  assert.equal(frontend.headers.get('content-security-policy'), expectedPolicy);
  assert(frontend.body.includes(`content="${expectedPolicy}"`), 'HTML meta CSP must allow the local WSS connection too');
  assert(frontend.body.includes('src="./entrypoints/inspector/inspector.js"'));
  const scriptPath = new URL('./entrypoints/inspector/inspector.js', inspector).pathname;
  const script = await tlsResponse('compose-ui.localhost', true, scriptPath);
  assert.equal(script.status, 200, script.body);
  assert.equal(script.headers.get('content-type'), 'text/javascript');
  assert.equal(script.body, 'export const inspector = true;');
  assert.equal((await tlsRequest('compose-ui.localhost', true,
    '/devtools-api/frontend/serve_rev/@abcdef/missing.js')).status, 404);
  assert.deepEqual(frontendRequests, ['/serve_rev/@abcdef/inspector.html',
    '/serve_rev/@abcdef/entrypoints/inspector/inspector.js', '/serve_rev/@abcdef/missing.js']);
  console.log('PASS: matching inspector assets through HTTPS workerd with local WSS allowed in header and meta CSP');
  const cdpVersion = await tlsRequest('compose-ui.localhost', true, '/devtools-api/json/version/');
  assert.equal(cdpVersion.status, 200, cdpVersion.body);
  assert.equal(JSON.parse(cdpVersion.body).Browser, 'Helium/153');
  assert.equal((await tlsRequest('compose-ui.localhost', true, '/devtools-api/json/list', 'https://evil.test')).status, 403);
  await verifyCDPWebSocket('/devtools-api/devtools/page/controlled-frame');
  await verifyCDPWebSocket('/devtools-api/devtools/browser');
  assert(browserCommands.some(command => command.method === 'Target.detachFromTarget'));
  console.log('PASS: browser discovery and CDP WebSockets on the public HTTPS listener through a private Unix socket');
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
  const inventory = await request('/v1.24/disk-usage');
  assert.equal(inventory.status, 200);
  assert.equal(JSON.parse(inventory.body.toString()).inventory.volumes[0].references, 0);
  assert(!seen.some(row => row.path === '/system/df'), 'opening disk usage never starts a scan');
  assert.equal((await request('/v1.24/disk-usage/scan')).status, 405);
  const scanned = await request('/v1.24/disk-usage/scan', { method: 'POST' });
  assert.equal(scanned.status, 200);
  assert.equal(JSON.parse(scanned.body.toString()).report.categories[0].totalBytes, 4096);
  assert.equal((await request('/v1.24/disk-usage/scan', { method: 'POST' })).status, 200);
  assert.equal(seen.filter(row => row.path === '/system/df').length, 1);
  console.log('PASS: metadata-only inventory, opt-in disk analysis and shared scan cache');
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

  // Workerd cancels request-owned I/O when a browser disconnects. A shared
  // discovery promise from that request must not strand every later app visit.
  await sleep(150);
  const discoveryStarted = new Promise<void>(resolve => { discoveryEntered = resolve; });
  const abandoned = httpRequest({ hostname: '127.0.0.1', port: routingPort,
    headers: { Host: `missing.localhost:${routingPort}` }, agent: false });
  abandoned.on('error', () => {});
  abandoned.end();
  await discoveryStarted;
  const overlapping = request('/', { app: true, host: 'web.localhost' });
  await sleep(50);
  abandoned.destroy();
  await sleep(100);
  releaseDiscovery!();
  releaseDiscovery = undefined;
  assert.equal((await overlapping).body.toString(), 'upstream-ok');
  await sleep(150);
  assert.equal((await request('/', { app: true, host: 'missing.localhost' })).status, 404);
  assert.equal((await request('/', appOptions)).body.toString(), 'upstream-ok');
  assert.deepEqual(await tlsRequest('web--p32000.app.localhost', true), { status: 200, body: 'upstream-ok' });
  console.log('PASS: cancelled app discovery does not strand later HTTP/HTTPS requests');

  await sleep(150);
  const stalledDiscovery = new Promise<void>(resolve => { discoveryEntered = resolve; });
  const stalledResponse = request('/', { ...appOptions, timeoutMs: 7000 });
  await stalledDiscovery;
  assert.equal((await stalledResponse).status, 503, 'stalled discovery returns before the client deadline');
  releaseDiscovery!();
  releaseDiscovery = undefined;
  assert.equal((await request('/', appOptions)).body.toString(), 'upstream-ok');
  assert.deepEqual(await tlsRequest('web--p32000.app.localhost', true), { status: 200, body: 'upstream-ok' });
  console.log('PASS: discovery deadline and retry, and duplicate project rows use their owning config');

  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'starting', bootId: 'integration-boot', message: 'Starting container runtime…', reason: null,
  }));
  await Deno.writeTextFile(join(statusPath, 'startup-services.json'), JSON.stringify([
    { project: 'demo', service: 'sleeping', path: 'demo/compose.yaml' },
  ]));
  async function notifyStartup() {
    const result = await new Deno.Command('curl', { args: [
      '--disable', '--noproxy', '*', '--silent', '--show-error', '--fail', '--max-time', '1',
      '--unix-socket', join(root, 'startup.sock'), '--output', '/dev/null',
      '--write-out', '%{http_code}', 'http://localhost/reconcile',
    ], stdout: 'piped', stderr: 'piped' }).output();
    assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
    assert.equal(new TextDecoder().decode(result.stdout), '202');
  }
  await notifyStartup();
  const waiting = await request('/deep/link?q=1', { app: true, host: 'sleeping_demo.localhost' });
  assert.match(waiting.body.toString(), /<h1>sleeping<\/h1>/);
  assert.match(waiting.body.toString(), /Starting container runtime…/);
  assert.match((await tlsRequest('sleeping_demo--nweb.app.localhost', true)).body, /Starting container runtime…/);
  assert.equal(seen.filter(r => r.path.startsWith('/v1.24/start/')).length, 0);
  assert.equal((await request()).status, 200, 'Compose UI stays available during runtime startup');
  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'healthy', bootId: 'integration-boot', message: 'Container runtime ready', reason: null,
  }));
  await notifyStartup();
  for (let i = 0; i < 100 && !releaseContainerStart; i++) await sleep(10);
  assert(releaseContainerStart, 'configured startup runs without a browser request');
  await notifyStartup();
  assert.equal((await request('/reconcile')).status, 404, 'the startup listener is private');
  // Optional extended check for builds that outlive a short request. Keep
  // notifying as the host supervisor does, with no app request holding it open.
  const startupHoldMs = Number(Deno.env.get('XE_TEST_STARTUP_HOLD_MS') || 0);
  const heldAt = Date.now();
  while (Date.now() - heldAt < startupHoldMs) {
    await sleep(Math.min(2000, startupHoldMs - (Date.now() - heldAt)));
    await notifyStartup();
    assert.equal((await request()).status, 200, 'management stays responsive during a long configured start');
    assert.equal(seen.filter(r => r.path.startsWith('/v1.24/start/')).length, 1);
  }
  const sleeping = await request('/deep/link?q=1', { app: true, host: 'sleeping_demo.localhost' });
  assert.equal(sleeping.status, 503);
  assert.match(sleeping.body.toString(), /<h1>sleeping<\/h1>/);
  assert.match(sleeping.body.toString(), /Starting…/);
  assert.equal(sleeping.headers['cache-control'], 'no-store');
  const sleepingTLS = await tlsRequest('sleeping_demo--nweb.app.localhost', true);
  assert.equal(sleepingTLS.status, 503);
  assert.match(sleepingTLS.body, /Starting…/);
  assert.equal(seen.filter(r => r.path.startsWith('/v1.24/start/')).length, 1);
  assert(releaseContainerStart, 'single-container start must be dispatched before returning the loader');
  assert.equal((await request()).status, 200, 'Compose UI stays available while a container build/start is pending');
  releaseContainerStart();
  releaseContainerStart = undefined;
  await sleep(2100);
  assert.equal((await request('/deep/link?q=1', { app: true, host: 'sleeping_demo.localhost' })).body.toString(), 'upstream-ok');
  assert.equal(seen.at(-1)!.path, '/deep/link?q=1');
  assert.deepEqual(await tlsRequest('sleeping_demo--p32002.app.localhost', true), { status: 200, body: 'upstream-ok' });
  const checkpoint = JSON.parse(await Deno.readTextFile(join(startupStatePath, 'boot.json')));
  assert.equal(checkpoint.bootId, 'integration-boot');
  assert.equal(checkpoint.attempted.length, 1);
  console.log('PASS: private readiness notification, configured startup, shared HTTP/HTTPS starts, durable boot checkpoint, and original URL recovery');

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
  for (const phase of ['starting', 'restarting']) {
    const message = phase === 'starting' ? 'Starting container runtime…' : 'Container VM ran out of memory; restarting…';
    await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
      phase, message, reason: phase === 'restarting' ? 'oom' : null,
    }));
    const loader = await request('/deep/link?q=1', { ...appOptions, headers: { Accept: 'text/html' } });
    assert.equal(loader.status, 503);
    assert.match(String(loader.headers['content-type']), /text\/html/);
    assert.equal(loader.headers['cache-control'], 'no-store');
    assert.equal(loader.headers['retry-after'], '2');
    assert(loader.body.toString().includes(message));
    assert.match(loader.body.toString(), /id="startup-cancel" type="button">Cancel<\/button>/);
    const tlsLoader = await tlsRequest('web--p32000.app.localhost', true);
    assert.equal(tlsLoader.status, 503);
    assert(tlsLoader.body.includes(message));
    const apiFailure = await request('/deep/link?q=1', { ...appOptions, headers: { Accept: 'application/json' } });
    assert.equal(JSON.parse(apiFailure.body.toString()).error,
      phase === 'restarting' ? 'container_runtime_oom' : 'container_runtime_unavailable');
  }
  assert.equal((await request()).status, 200);
  await Deno.writeTextFile(join(statusPath, 'status.json'), JSON.stringify({
    phase: 'healthy', message: 'Container runtime ready', reason: null,
  }));
  compose = await startUnix(composePath);
  docker = await startUnix(dockerPath);
  assert.equal((await request('/v1.24/ls')).status, 200);
  assert.equal((await request('/deep/link?q=1', appOptions)).body.toString(), 'upstream-ok');
  assert.deepEqual(await tlsRequest('web--p32000.app.localhost', true), { status: 200, body: 'upstream-ok' });
  console.log('PASS: runtime HTTP/HTTPS loader, API JSON, and backend recovery without restarting workerd');

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
  console.error('Recent backend requests:', seen.slice(-12).map(({ path, method }) => ({ path, method })));
  for (const process of processes) await stopProcess(process);
  for (const output of outputs) console.error(new TextDecoder().decode((await output).stderr));
  throw error;
  } finally { tlsApp.close(); }
} finally {
  cdpListener?.close();
  for (const connection of cdpClients) { try { connection.close(); } catch { /* closed */ } }
  releaseSSE?.();
  releaseContainerStart?.();
  releaseDiscovery?.();
  for (const process of processes) await stopProcess(process);
  for (const server of servers) await server.shutdown();
  await app.shutdown();
  await Deno.remove(root, { recursive: true });
}
