// Compose's parsed config retains port names and YAML list order. Docker's
// container listing supplies the running service identity and published ports.
const configs = new Map();
const targetHeader = 'x-xe-target-port';
const containerHeader = 'x-xe-container-id';

async function servicePorts(env, service) {
  const url = new URL(`http://compose/v1.24/config/${encodeURIComponent(service.project)}`);
  url.searchParams.set('format', 'json');
  if (service.configFiles) url.searchParams.set('path', service.configFiles);
  const key = url.href;
  let entry = configs.get(key);
  if (!entry || entry.expires <= Date.now()) {
    // Keep this cache bounded when projects are added and removed.
    for (const [key, value] of configs) if (value.expires <= Date.now()) configs.delete(key);
    if (configs.size >= 128) configs.delete(configs.keys().next().value);
    entry = { expires: Date.now() + 2000, promise: (async () => {
      const response = await env.COMPOSE.fetch(url.href);
      if (!response.ok) throw new Error('Compose configuration unavailable');
      return await response.json();
    })() };
    configs.set(key, entry);
  }
  let config;
  try { config = await entry.promise; } catch (error) {
    if (configs.get(key) === entry) configs.delete(key);
    throw error;
  }
  return config.services?.[service.service]?.ports || [];
}

export async function routeApplication(request, env) {
  const url = new URL(request.url);
  const labels = url.hostname.split('.');
  const name = labels[0];
  const selector = labels.length === 3 ? labels[1] : undefined;
  const headers = new Headers(request.headers);
  // Never trust routing instructions supplied by a browser or container app.
  headers.delete(targetHeader);
  headers.delete(containerHeader);
  if (selector === undefined || !/^\d+$/.test(selector)) {
    const resolved = await env.ROUTER.fetch(`http://localhost/__xe_router_service?name=${encodeURIComponent(name)}`);
    if (!resolved.ok) return resolved;
    const service = await resolved.json();
    const ports = (await servicePorts(env, service)).filter(p => (p.protocol || 'tcp') === 'tcp');
    const selected = selector === undefined ? ports.slice(0, 1)
      : ports.filter(p => typeof p.name === 'string' && p.name.toLowerCase() === selector);
    if (selected.length !== 1) {
      return new Response(selected.length ? 'Ambiguous port name' : 'Compose port not available', { status: 404 });
    }
    const port = selected[0].target;
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      return new Response('Invalid Compose target port', { status: 404 });
    }
    headers.set(targetHeader, String(port));
    headers.set(containerHeader, service.id);
  }
  return env.ROUTER.fetch(new Request(request, { headers }));
}
