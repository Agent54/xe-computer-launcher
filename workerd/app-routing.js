import { readAppPorts } from './app-ports.js';

// Compose's parsed config retains port names and YAML list order. Docker's
// container listing supplies the running service identity and published ports.
const configs = new Map();
const targetHeader = 'x-xe-target-port';
const containerHeader = 'x-xe-container-id';

function applicationProtocol(port) {
  const value = port.app_protocol ?? port.appProtocol;
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

function routeLabels(hostname) {
  if (!hostname.endsWith('.app.localhost')) return hostname.split('.');
  const alias = hostname.slice(0, -'.app.localhost'.length);
  const selectedPort = /^(.*)--p([1-9]\d{0,4})$/.exec(alias);
  if (selectedPort) return [selectedPort[1], selectedPort[2], 'localhost'];
  const namedPort = /^(.*)--n([a-z0-9](?:[a-z0-9-]*[a-z0-9])?)$/.exec(alias);
  return namedPort ? [namedPort[1], namedPort[2], 'localhost'] : [alias, 'localhost'];
}

export async function resolveApplicationPort(hostname, env) {
  const labels = routeLabels(hostname);
  const name = labels[0];
  const selector = labels.length === 3 ? labels[1] : undefined;
  const resolved = await env.ROUTER.fetch(`http://localhost/__xe_router_service?name=${encodeURIComponent(name)}`);
  if (!resolved.ok) return null;
  const service = await resolved.json();
  const ports = (await servicePorts(env, service)).filter(p => (p.protocol || 'tcp') === 'tcp');
  const selected = selector === undefined ? ports.slice(0, 1)
    : /^\d+$/.test(selector) ? ports.filter(p => Number(p.published) === Number(selector))
    : ports.filter(p => typeof p.name === 'string' && p.name.toLowerCase() === selector);
  if (selected.length !== 1) return null;
  const port = selected[0];
  if (!Number.isInteger(port.target) || port.target < 1 || port.target > 65535 ||
      !publishedPortFor(service, port)) return null;
  return { service, port, protocol: applicationProtocol(port) || 'http' };
}

function publishedPortFor(service, port) {
  const target = Number(port.target);
  const configured = Number(port.published);
  const published = [...new Set((service.publishedPorts || [])
    .filter(mapping => mapping.target === target &&
      (!Number.isInteger(configured) || mapping.published === configured))
    .map(mapping => mapping.published))];
  return published.length === 1 ? published[0] : undefined;
}

async function protocolResponse(request, service, port, env, canonical = false) {
  const protocol = applicationProtocol(port);
  if (!protocol || protocol === 'http') return null;
  if (protocol !== 'https') {
    return new Response(`Unsupported Compose application protocol: ${protocol}`, { status: 404 });
  }
  const published = publishedPortFor(service, port);
  if (!published) return new Response('Published HTTPS port not available', { status: 404 });
  const url = new URL(request.url);
  if (url.protocol === 'https:' && !url.hostname.endsWith('.app.localhost')) {
    return new Response('HTTPS application route changed; retry', { status: 503, headers: { 'Retry-After': '2' } });
  }
  url.protocol = 'https:';
  if (url.hostname.endsWith('.app.localhost')) {
    const [name, selector] = routeLabels(url.hostname);
    url.hostname = canonical ? `${name}.localhost` : `${name}.${selector || published}.localhost`;
  } else if (canonical) url.hostname = `${url.hostname.split('.')[0]}.localhost`;
  const ports = await readAppPorts(env);
  if (!ports || !ports.publicHttpReady) {
    return new Response('Selected local app ports are unavailable', { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
  const { https } = ports;
  url.port = https === 443 ? '' : String(https);
  return new Response(null, {
    status: 307,
    headers: { Location: url.href, 'Cache-Control': 'no-store' },
  });
}

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
  const labels = routeLabels(url.hostname);
  const name = labels[0];
  const selector = labels.length === 3 ? labels[1] : undefined;
  const headers = new Headers(request.headers);
  // Never trust routing instructions supplied by a browser or container app.
  headers.delete(targetHeader);
  headers.delete(containerHeader);
  headers.delete('x-xe-origin-proto');
  headers.delete('x-xe-public-host');
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
    const response = await protocolResponse(request, service, selected[0], env, selected[0] === ports[0]);
    if (response) return response;
    headers.set(targetHeader, String(port));
    headers.set(containerHeader, service.id);
  } else {
    // Numeric routes keep working when Compose configuration is unavailable,
    // but use its application protocol when the matching entry can be read.
    try {
      const resolved = await env.ROUTER.fetch(`http://localhost/__xe_router_service?name=${encodeURIComponent(name)}`);
      if (resolved.ok) {
        const service = await resolved.json();
        const ports = (await servicePorts(env, service)).filter(p => (p.protocol || 'tcp') === 'tcp');
        const selected = ports.filter(p =>
          (p.protocol || 'tcp') === 'tcp' && Number(p.published) === Number(selector));
        if (selected.length === 1) {
          const response = await protocolResponse(request, service, selected[0], env, selected[0] === ports[0]);
          if (response) return response;
        }
      }
    } catch {
      // The guest router remains the source of truth for numeric HTTP routes.
    }
  }
  headers.set('x-xe-origin-proto', url.protocol === 'https:' ? 'https' : 'http');
  headers.set('x-xe-public-host', url.host);
  // The guest router speaks HTTP on its private Unix socket even when the
  // public connection was terminated as HTTPS by the host.
  url.protocol = 'http:';
  url.port = '';
  return env.ROUTER.fetch(new Request(url, {
    method: request.method, headers, body: request.body, redirect: 'manual',
  }));
}
