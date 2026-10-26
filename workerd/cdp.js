import { rewriteCDPPayload } from './cdp-payload.js';

export const cdpPrefix = '/devtools-api';
const maximumMessage = 32 * 1024 * 1024;
const allowedOrigins = new Set([
  'isolated-app://cjmvvyipbvzrcsssdqwerai5ohqiwkuyf6jf4jonrwdzucmc3d2aaaic',
  'https://localhost:5194',
  'https://chrome-devtools-frontend.appspot.com',
]);

function response(body, status = 200, origin) {
  const headers = new Headers({ 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  if (origin) {
    headers.set('Access-Control-Allow-Origin', origin);
    headers.set('Vary', 'Origin');
  }
  return new Response(JSON.stringify(body), { status, headers });
}

export function isCDPPath(path) {
  return path === cdpPrefix || path.startsWith(`${cdpPrefix}/`);
}

// Each HTTP request or WebSocket gets its own browser session. The native
// transport remaps command IDs; this layer keeps clients' session events apart.
export async function connectCDP(env, context, onEvent = (_message) => {}) {
  const socket = await env.CDP.connect('localhost:9226');
  const writer = socket.writable.getWriter();
  const reader = socket.readable.getReader();
  const pending = new Map();
  const sessions = new Set();
  let nextID = 0;
  let rootSession;
  let closed = false;
  let closing;
  let writes = Promise.resolve();
  let finish;
  const done = new Promise(resolve => { finish = resolve; });

  function disconnected() {
    if (closed) return;
    closed = true;
    for (const { reject, timer } of pending.values()) {
      clearTimeout(timer);
      reject(new Error('Browser disconnected'));
    }
    pending.clear();
    finish();
    socket.close().catch(() => {});
  }

  async function request(method, params = {}, sessionId = rootSession, timeout = 5000) {
    if (closed) throw new Error('Browser disconnected');
    const id = ++nextID;
    const message = await rewriteCDPPayload({ id, method, params,
      ...(sessionId ? { sessionId } : {}),
    }, { ...context, direction: 'to-browser' });
    const data = new TextEncoder().encode(`${JSON.stringify(message)}\0`);
    if (data.length > maximumMessage) throw new Error('CDP message is too large');
    const result = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Browser command timed out: ${method}`));
      }, timeout);
      pending.set(id, { resolve, reject, timer });
    });
    writes = writes.then(() => writer.write(data));
    writes.catch(disconnected);
    return result;
  }

  async function receive(data) {
    const message = await rewriteCDPPayload(JSON.parse(data), { ...context, direction: 'from-browser' });
    if (Number.isInteger(message.id)) {
      const waiting = pending.get(message.id);
      if (!waiting) return;
      pending.delete(message.id);
      clearTimeout(waiting.timer);
      waiting.resolve(message);
      return;
    }
    if (!sessions.has(message.sessionId)) return;
    if (message.method === 'Target.attachedToTarget') sessions.add(message.params.sessionId);
    if (message.method === 'Target.detachedFromTarget') sessions.delete(message.params.sessionId);
    if (message.sessionId === rootSession) delete message.sessionId;
    onEvent(message);
  }

  async function read() {
    const decoder = new TextDecoder();
    let buffer = '';
    try {
      await socket.opened;
      while (!closed) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let delimiter;
        while ((delimiter = buffer.indexOf('\0')) !== -1) {
          if (delimiter > maximumMessage) throw new Error('CDP message is too large');
          const data = buffer.slice(0, delimiter);
          buffer = buffer.slice(delimiter + 1);
          await receive(data);
        }
        if (buffer.length > maximumMessage) throw new Error('CDP message is too large');
      }
    } finally {
      disconnected();
      reader.releaseLock();
    }
  }
  const reading = read().catch(disconnected);

  function close() {
    if (!closing) closing = (async () => {
      if (!closed && rootSession) {
        try { await request('Target.detachFromTarget', { sessionId: rootSession }, null, 1000); } catch { /* browser exited */ }
      }
      disconnected();
      await reading;
      await writes.catch(() => {});
      writer.releaseLock();
    })();
    return closing;
  }

  try {
    const attached = await request('Target.attachToBrowserTarget', {}, null);
    if (attached.error || !attached.result?.sessionId) throw new Error('Cannot attach to browser');
    rootSession = attached.result.sessionId;
    sessions.add(rootSession);
  } catch (error) {
    await close();
    throw error;
  }

  return {
    done, close,
    async command(method, params = {}, sessionId) {
      const reply = await request(method, params, sessionId);
      if (reply.error) throw new Error(reply.error.message);
      return reply.result;
    },
    async forward(message) {
      if (!Number.isInteger(message.id) || typeof message.method !== 'string' ||
          (message.sessionId && !sessions.has(message.sessionId))) {
        throw new Error('Invalid CDP command or session');
      }
      const reply = await request(message.method, message.params, message.sessionId);
      if (['Target.attachToTarget', 'Target.attachToBrowserTarget'].includes(message.method) && reply.result?.sessionId) {
        sessions.add(reply.result.sessionId);
      }
      reply.id = message.id;
      if (reply.sessionId === rootSession) delete reply.sessionId;
      return reply;
    },
    async attach(targetId) {
      const reply = await request('Target.attachToTarget', { targetId, flatten: true });
      if (reply.error || !reply.result?.sessionId) throw new Error('Cannot attach to target');
      sessions.add(reply.result.sessionId);
      return reply.result.sessionId;
    },
  };
}

function socketURL(url, path) {
  return `wss://${url.host}${cdpPrefix}/devtools/${path}`;
}

export function inspectorURL(version, webSocketURL) {
  // Use Chromium's matching hosted frontend; no second local web server is needed.
  const revision = version.revision;
  if (!/^@[a-f0-9]+$/i.test(revision || '')) throw new Error('Browser frontend revision is unavailable');
  const url = new URL(`https://chrome-devtools-frontend.appspot.com/serve_rev/${revision}/inspector.html`);
  url.searchParams.set('wss', webSocketURL.replace(/^wss:\/\//, ''));
  return url.href;
}

export async function handleCDP(request, env, ctx) {
  const url = new URL(request.url);
  const origin = request.headers.get('Origin');
  if (url.protocol !== 'https:' ||
      (origin && origin !== url.origin && !allowedOrigins.has(origin)) ||
      (!origin && request.headers.get('Sec-Fetch-Site') === 'cross-site')) {
    return response({ error: 'Forbidden' }, 403);
  }
  const corsOrigin = origin && (origin === url.origin || allowedOrigins.has(origin)) ? origin : null;
  if (request.method === 'OPTIONS') {
    if (request.headers.get('Access-Control-Request-Method') !== 'GET' ||
        request.headers.get('Access-Control-Request-Headers')) return response({ error: 'Forbidden' }, 403);
    const headers = new Headers({ 'Access-Control-Allow-Methods': 'GET', 'Cache-Control': 'no-store' });
    if (corsOrigin) headers.set('Access-Control-Allow-Origin', corsOrigin);
    headers.set('Vary', 'Origin, Access-Control-Request-Method, Access-Control-Request-Headers, Access-Control-Request-Private-Network');
    if (request.headers.get('Access-Control-Request-Private-Network') === 'true') {
      headers.set('Access-Control-Allow-Private-Network', 'true');
    }
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== 'GET') return response({ error: 'Method not allowed' }, 405, corsOrigin);
  const path = url.pathname.slice(cdpPrefix.length).replace(/\/$/, '');
  const websocket = request.headers.get('Upgrade')?.toLowerCase() === 'websocket';
  const target = /^\/devtools\/page\/([a-zA-Z0-9-]+)$/.exec(path)?.[1];
  if (websocket ? path !== '/devtools/browser' && !target :
      !['/json', '/json/list', '/json/version'].includes(path) && !/^\/json\/(?:activate|close)\/[a-zA-Z0-9-]+$/.test(path)) {
    return response({ error: 'Not found' }, 404, corsOrigin);
  }
  let connection;
  let server;
  let pageSession;
  const context = { connectionId: crypto.randomUUID(), url: request.url };
  try {
    connection = await connectCDP(env, context, message => {
      if (pageSession && message.sessionId === pageSession) delete message.sessionId;
      server?.send(JSON.stringify(message));
    });
    if (websocket) {
      if (target) pageSession = await connection.attach(target);
      const pair = new WebSocketPair();
      const client = pair[0];
      server = pair[1];
      server.accept();
      const close = () => ctx.waitUntil(connection.close());
      server.addEventListener('close', close, { once: true });
      server.addEventListener('error', close, { once: true });
      server.addEventListener('message', event => {
        const task = (async () => {
          let message;
          try {
            if (typeof event.data !== 'string' || event.data.length > maximumMessage) throw new Error('Invalid CDP message');
            message = JSON.parse(event.data);
            const reply = await connection.forward({ ...message,
              ...(pageSession && !message.sessionId ? { sessionId: pageSession } : {}),
            });
            if (pageSession && reply.sessionId === pageSession) delete reply.sessionId;
            server.send(JSON.stringify(reply));
          } catch (error) {
            if (Number.isInteger(message?.id)) {
              server.send(JSON.stringify({ id: message.id, error: { code: -32000, message: error.message },
                ...(message.sessionId ? { sessionId: message.sessionId } : {}),
              }));
            } else { server.close(1003, 'Invalid CDP message'); }
          }
        })();
        ctx.waitUntil(task.catch(() => connection.close()));
      });
      ctx.waitUntil(connection.done.then(() => { try { server.close(1011, 'Browser disconnected'); } catch { /* already closed */ } }));
      return new Response(null, { status: 101, webSocket: client });
    }
    try {
      if (path === '/json/version') {
        const version = await connection.command('Browser.getVersion');
        return response({ Browser: version.product, 'Protocol-Version': version.protocolVersion,
          'User-Agent': version.userAgent, 'V8-Version': version.jsVersion,
          webSocketDebuggerUrl: socketURL(url, 'browser'),
        }, 200, corsOrigin);
      }
      if (path === '/json' || path === '/json/list') {
        const { targetInfos } = await connection.command('Target.getTargets');
        const version = await connection.command('Browser.getVersion');
        return response(targetInfos.map(target => {
          const webSocketDebuggerUrl = socketURL(url, `page/${target.targetId}`);
          return { ...target, id: target.targetId, description: '',
            webSocketDebuggerUrl, devtoolsFrontendUrl: inspectorURL(version, webSocketDebuggerUrl),
          };
        }), 200, corsOrigin);
      }
      const [, action, targetId] = /^\/json\/(activate|close)\/([a-zA-Z0-9-]+)$/.exec(path);
      await connection.command(action === 'close' ? 'Target.closeTarget' : 'Target.activateTarget', { targetId });
      return response({ ok: true }, 200, corsOrigin);
    } finally { await connection.close(); }
  } catch {
    if (connection) await connection.close();
    return response({ error: 'CDP unavailable' }, 503, corsOrigin);
  }
}
