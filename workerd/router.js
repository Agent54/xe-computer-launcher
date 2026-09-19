// Runs inside the guest. Resolve Compose names to container IPs and private
// ports, as in docker/legacy.js, without exposing each port on macOS.
let cached = null;
let expires = 0;
let loading = null;

async function discover(env) {
  if (cached && Date.now() < expires) return cached;
  if (!loading) loading = (async () => {
    const response = await env.DOCKER.fetch('http://docker/containers/json');
    if (!response.ok) throw new Error('Docker discovery unavailable');
    const containers = await response.json();
    if (!Array.isArray(containers)) throw new Error('Invalid Docker response');
    cached = containers;
    expires = Date.now() + 2000;
    return containers;
  })().finally(() => { loading = null; });
  return loading;
}

function matchService(containers, name) {
  const matches = containers.filter(c => {
    const service = c.Labels?.['com.docker.compose.service'];
    const project = c.Labels?.['com.docker.compose.project'];
    const number = c.Labels?.['com.docker.compose.container-number'];
    const suffix = Number(number) > 1 ? `_${number}` : '';
    return service && (name === `${service}${suffix}` || name === `${service}_${project}${suffix}`);
  });
  return matches.length === 1 ? matches[0] : new Response(
    matches.length ? 'Ambiguous service; include its project name.' : 'Service not found', { status: 404 });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/__xe_router_health' && url.hostname === 'localhost') {
      return new Response('ready');
    }
    // Only the host worker can use this lookup over the guest socket. The
    // public gateway rejects localhost and never exposes this response itself.
    const lookup = url.origin === 'http://localhost' && url.pathname === '/__xe_router_service' && request.method === 'GET';
    if (!lookup && (url.protocol !== 'http:' || url.port !== '5196' ||
        !/^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)?\.localhost$/.test(url.hostname))) {
      return new Response('Invalid application hostname', { status: 403 });
    }
    const [name, portPart] = url.hostname.split('.');
    try {
      const containers = await discover(env);
      const container = matchService(containers, lookup ? url.searchParams.get('name') : name);
      if (container instanceof Response) return container;
      if (lookup) return Response.json({
        id: container.Id,
        service: container.Labels['com.docker.compose.service'],
        project: container.Labels['com.docker.compose.project'],
        configFiles: container.Labels['com.docker.compose.project.config_files'],
      });
      const numeric = /^\d+$/.test(portPart);
      const published = (container.Ports || []).filter(p => p.Type === 'tcp' &&
        Number.isInteger(p.PublicPort) && p.PublicPort > 0 && p.PublicPort < 65536);
      const targets = [...new Set(published.filter(p => p.PublicPort === Number(portPart)).map(p => p.PrivatePort))];
      if (numeric && targets.length !== 1) {
        return new Response(targets.length ? 'Ambiguous published port' : 'Published port not available', { status: 404 });
      }
      const port = numeric ? targets[0] : Number(request.headers.get('x-xe-target-port'));
      if (!numeric && request.headers.get('x-xe-container-id') !== container.Id) {
        return new Response('Service changed; retry the request', { status: 503, headers: { 'Retry-After': '2' } });
      }
      if (!Number.isInteger(port) || port < 1 || port > 65535 || !published.some(p => p.PrivatePort === port)) {
        return new Response('Published port not available', { status: 404 });
      }
      const networks = container.NetworkSettings?.Networks || {};
      const address = Object.values(networks).map(n => n.IPAddress).find(ip => ip);
      if (!address) throw new Error('Container network unavailable');
      const headers = new Headers(request.headers);
      headers.delete('x-xe-target-port');
      headers.delete('x-xe-container-id');
      headers.delete('forwarded');
      headers.delete('x-forwarded-for');
      headers.set('x-forwarded-host', url.host);
      headers.set('x-forwarded-proto', 'http');
      url.hostname = address;
      url.port = String(port);
      // Manual redirects ensure a backend cannot make the router fetch another
      // host. Passing the response through also preserves WebSocket upgrades.
      return await fetch(new Request(url, { method: request.method, headers, body: request.body, redirect: 'manual' }));
    } catch {
      cached = null;
      expires = 0;
      return new Response('Container runtime unavailable. Retry when the VM is ready.',
        { status: 503, headers: { 'Retry-After': '2', 'Cache-Control': 'no-store' } });
    }
  },
};
