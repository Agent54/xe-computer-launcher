import { clientHelloServerName } from './tls-client-hello.js';
import { resolveApplicationPort } from './app-routing.js';
import { bridgeSocketAndWebSocket } from './socket-bridge.js';

const applicationHost = /^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost$/;

async function readClientHello(socket) {
  const reader = socket.readable.getReader();
  let buffer = new Uint8Array(0);
  try {
    while (buffer.length < 65536) {
      const { value, done } = await Promise.race([
        reader.read(),
        new Promise((_, reject) => setTimeout(() => reject(new Error('TLS ClientHello timed out')), 5000)),
      ]);
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
      const route = await resolveApplicationPort(hostname, env);
      if (!route || route.protocol !== 'https') return;
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
