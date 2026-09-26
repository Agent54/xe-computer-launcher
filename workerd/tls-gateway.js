import { clientHelloServerName } from './tls-client-hello.js';
import { resolveApplicationPort } from './app-routing.js';
import { isApplicationStopped, startApplication } from './app-startup.js';
import { bridgeSocketAndSocket, bridgeSocketAndWebSocket } from './socket-bridge.js';

const applicationHost = /^(?:[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost|[a-z0-9][a-z0-9_-]*\.app\.localhost)$/;
const uiHost = 'compose-ui.localhost';

async function readClientHello(socket) {
  const reader = socket.readable.getReader();
  let buffer = new Uint8Array(0);
  try {
    while (buffer.length < 65536) {
      let timeout;
      let chunk;
      try {
        chunk = await Promise.race([
          reader.read(),
          new Promise((_, reject) => {
            timeout = setTimeout(() => reject(new Error('TLS ClientHello timed out')), 5000);
          }),
        ]);
      } finally { clearTimeout(timeout); }
      const { value, done } = chunk;
      if (done) break;
      const next = new Uint8Array(buffer.length + value.length);
      next.set(buffer);
      next.set(value, buffer.length);
      buffer = next;
      const hostname = clientHelloServerName(buffer);
      if (hostname !== undefined) return { hostname, buffer };
    }
    return { hostname: null, buffer };
  } finally { reader.releaseLock(); }
}

export default {
  async connect(socket, env) {
    try {
      const { hostname, buffer } = await readClientHello(socket);
      if (!hostname || !applicationHost.test(hostname) || hostname === 'api.moby.localhost') return;
      if (hostname === uiHost || hostname.endsWith('.app.localhost')) {
        const upstream = await env.UI_TLS.connect('localhost:443');
        await bridgeSocketAndSocket(socket, upstream, buffer);
        return;
      }
      const route = await resolveApplicationPort(hostname, env);
      if (!route) return;
      if (route.protocol === 'http') {
        const upstream = await env.UI_TLS.connect('localhost:443');
        await bridgeSocketAndSocket(socket, upstream, buffer);
        return;
      }
      if (route.protocol !== 'https') return;
      // Native HTTPS apps own their certificate. Start the exact container and
      // let the client retry its TLS connection once the application is ready.
      if (isApplicationStopped(route.service)) {
        await startApplication(route.service, env).promise;
        return;
      }
      const response = await env.ROUTER.fetch(new Request('http://localhost/__xe_tls_tunnel', {
        headers: {
          Upgrade: 'websocket',
          'x-xe-container-id': route.service.id,
          'x-xe-target-port': String(route.port.target),
        },
      }));
      if (response.status !== 101 || !response.webSocket) return;
      await bridgeSocketAndWebSocket(socket, response.webSocket, buffer);
    } catch (error) {
      console.warn('TLS route failed:', error);
    } finally {
      try { await socket.close(); } catch {}
    }
  },
};
