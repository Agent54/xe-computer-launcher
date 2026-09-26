import { bridgeSocketAndWebSocket } from './socket-bridge.js';

// Runs inside the guest. Validate the host's exact container/port selection and
// resolve its live network address without exposing each port on macOS.
let cached = null;
let expires = 0;
let loading = null;
const cacheLifetime = 100;

async function discover(env) {
  if (cached && Date.now() < expires) return cached;
  if (!loading) loading = (async () => {
    const requestedAt = Date.now();
    const response = await env.DOCKER.fetch('http://docker/containers/json?all=true');
    if (!response.ok) throw new Error('Docker discovery unavailable');
    const containers = await response.json();
    if (!Array.isArray(containers)) throw new Error('Invalid Docker response');
    cached = containers;
    expires = requestedAt + cacheLifetime;
    return containers;
  })().finally(() => { loading = null; });
  return loading;
}

async function findContainer(id, env) {
  let containers = await discover(env);
  // A successful create can provide a new ID before the Docker cache expires.
  if (!containers.some(container => container.Id === id)) {
    cached = null;
    containers = await discover(env);
  }
  return containers.find(container => container.Id === id &&
    container.Labels?.['com.docker.compose.service'] && container.Labels?.['com.docker.compose.project'] &&
    container.Labels?.['com.docker.compose.oneoff']?.toLowerCase() !== 'true');
}

function publishedTarget(container, port, published) {
  const targets = new Set((container.Ports || [])
    .filter(binding => binding.Type === 'tcp' && binding.PublicPort === published)
    .map(binding => binding.PrivatePort));
  return targets.size === 1 && targets.has(port);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/__xe_router_health' && url.hostname === 'localhost') {
      return new Response('ready');
    }
    if (url.origin === 'http://localhost' && url.pathname === '/__xe_tls_tunnel' &&
        request.method === 'GET' && request.headers.get('upgrade')?.toLowerCase() === 'websocket') {
      const id = request.headers.get('x-xe-container-id');
      const port = Number(request.headers.get('x-xe-target-port'));
      const published = Number(request.headers.get('x-xe-published-port'));
      if (!/^[a-f0-9]{64}$/.test(id || '') || !Number.isInteger(port) || port < 1 || port > 65535 ||
          !Number.isInteger(published) || published < 1 || published > 65535) {
        return new Response('Invalid TLS tunnel target', { status: 403 });
      }
      try {
        const container = await findContainer(id, env);
        if (!container || container.State !== 'running' || !publishedTarget(container, port, published)) {
          return new Response('TLS target unavailable', { status: 404 });
        }
        const address = Object.values(container.NetworkSettings?.Networks || {}).map(n => n.IPAddress).find(ip => ip);
        if (!address) return new Response('TLS target unavailable', { status: 503 });
        const { connect } = await import('cloudflare:sockets');
        const upstream = connect({ hostname: address, port });
        await upstream.opened;
        const pair = new WebSocketPair();
        const [client, server] = Object.values(pair);
        ctx.waitUntil(bridgeSocketAndWebSocket(upstream, server));
        return new Response(null, { status: 101, webSocket: client });
      } catch {
        return new Response('TLS target unavailable', { status: 503 });
      }
    }
    if (url.protocol !== 'http:' || url.port !== '' ||
        !/^(?:[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost|[a-z0-9][a-z0-9_-]*\.app\.localhost)$/.test(url.hostname)) {
      return new Response('Invalid application hostname', { status: 403, headers: { 'Cache-Control': 'no-store' } });
    }
    const id = request.headers.get('x-xe-container-id');
    const port = Number(request.headers.get('x-xe-target-port'));
    const published = Number(request.headers.get('x-xe-published-port'));
    if (!id || !Number.isInteger(port) || port < 1 || port > 65535 ||
        !Number.isInteger(published) || published < 1 || published > 65535) {
      return new Response('Invalid application target', { status: 403, headers: { 'Cache-Control': 'no-store' } });
    }
    try {
      const container = await findContainer(id, env);
      if (!container || container.State !== 'running') throw new Error('Container is not running');
      if (!publishedTarget(container, port, published)) {
        return new Response('Published port not available', { status: 404, headers: { 'Cache-Control': 'no-store' } });
      }
      const networks = container.NetworkSettings?.Networks || {};
      const address = Object.values(networks).map(n => n.IPAddress).find(ip => ip);
      if (!address) throw new Error('Container network unavailable');
      const headers = new Headers(request.headers);
      headers.delete('x-xe-target-port');
      headers.delete('x-xe-container-id');
      headers.delete('x-xe-published-port');
      headers.delete('forwarded');
      headers.delete('x-forwarded-for');
      const publicHost = headers.get('x-xe-public-host');
      headers.delete('x-xe-public-host');
      headers.set('x-forwarded-host', publicHost === url.hostname ||
        (publicHost?.startsWith(`${url.hostname}:`) && /^\d{1,5}$/.test(publicHost.slice(url.hostname.length + 1)))
        ? publicHost : url.host);
      headers.set('x-forwarded-proto', headers.get('x-xe-origin-proto') === 'https' ? 'https' : 'http');
      headers.delete('x-xe-origin-proto');
      url.hostname = address;
      url.port = String(port);
      // Manual redirects ensure a backend cannot make the router fetch another
      // host. Passing the response through also preserves WebSocket upgrades.
      const response = await fetch(new Request(url, { method: request.method, headers, body: request.body, redirect: 'manual' }));
      // This header belongs to the router, never to an upstream application.
      if (!response.headers.has('x-xe-router-unavailable')) return response;
      const responseHeaders = new Headers(response.headers);
      responseHeaders.delete('x-xe-router-unavailable');
      return new Response(response.body, { status: response.status, statusText: response.statusText, headers: responseHeaders });
    } catch {
      cached = null;
      expires = 0;
      return new Response('Container runtime unavailable. Retry when the VM is ready.',
        { status: 503, headers: { 'Retry-After': '2', 'Cache-Control': 'no-store', 'x-xe-router-unavailable': 'true' } });
    }
  },
};
