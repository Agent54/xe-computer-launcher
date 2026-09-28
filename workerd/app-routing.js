import { readAppPorts } from './app-ports.js';
import { invalidateApplicationService, resolveApplicationService } from './app-discovery.js';
import { applicationReady, applicationStart, applicationStarting, isApplicationStopped, startApplication } from './app-startup.js';

const targetHeader = 'x-xe-target-port';
const containerHeader = 'x-xe-container-id';
const publishedHeader = 'x-xe-published-port';

function routeError(message, status = 404, headers = {}) {
  return new Response(message, { status, headers: { ...headers, 'Cache-Control': 'no-store' } });
}

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
  const service = await resolveApplicationService(name, env);
  if (service instanceof Response) return null;
  const ports = servicePorts(service);
  const selected = selector === undefined ? ports.slice(0, 1)
    : /^\d+$/.test(selector) ? ports.filter(p => Number(p.published) === Number(selector))
    : ports.filter(p => typeof p.name === 'string' && p.name.toLowerCase() === selector);
  if (selected.length !== 1) return null;
  const port = selected[0];
  const published = publishedPortFor(service, port);
  if (!Number.isInteger(port.target) || port.target < 1 || port.target > 65535 || !published) return null;
  return { service, port, published, protocol: applicationProtocol(port) || 'http' };
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
    return routeError(`Unsupported Compose application protocol: ${protocol}`);
  }
  const published = publishedPortFor(service, port);
  if (!published) return routeError('Published HTTPS port not available');
  const url = new URL(request.url);
  if (url.protocol === 'https:' && !url.hostname.endsWith('.app.localhost')) {
    return routeError('HTTPS application route changed; retry', 503, { 'Retry-After': '2' });
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

function servicePorts(service) {
  if (!service.ports) throw new Error('Compose configuration unavailable');
  return service.ports.filter(port => (port.protocol || 'tcp') === 'tcp');
}

export async function routeApplication(request, env, ctx) {
  const url = new URL(request.url);
  const labels = routeLabels(url.hostname);
  const name = labels[0];
  const selector = labels.length === 3 ? labels[1] : undefined;
  const headers = new Headers(request.headers);
  // Never trust routing instructions supplied by a browser or container app.
  headers.delete(targetHeader);
  headers.delete(containerHeader);
  headers.delete(publishedHeader);
  headers.delete('x-xe-origin-proto');
  headers.delete('x-xe-public-host');
  const service = await resolveApplicationService(name, env);
  if (service instanceof Response) return service;
  let selectedPort;
  let target;
  let published;
  let canonical = false;
  if (selector === undefined || !/^\d+$/.test(selector)) {
    const ports = servicePorts(service);
    const selected = selector === undefined ? ports.slice(0, 1)
      : ports.filter(p => typeof p.name === 'string' && p.name.toLowerCase() === selector);
    if (selected.length !== 1) {
      return routeError(selected.length ? 'Ambiguous port name' : 'Compose port not available');
    }
    const port = selected[0].target;
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      return routeError('Invalid Compose target port');
    }
    published = publishedPortFor(service, selected[0]);
    if (!published) {
      return routeError('Published port not available');
    }
    selectedPort = selected[0];
    canonical = selected[0] === ports[0];
    target = port;
  } else {
    // Numeric routes keep working when Compose configuration is unavailable,
    // but use its application protocol when the matching entry can be read.
    const targets = [...new Set((service.publishedPorts || [])
      .filter(p => p.published === Number(selector)).map(p => p.target))];
    if (targets.length !== 1) {
      return routeError(targets.length ? 'Ambiguous published port' : 'Published port not available');
    }
    target = targets[0];
    published = Number(selector);
    try {
      const ports = servicePorts(service);
      const selected = ports.filter(p => Number(p.published) === Number(selector));
      if (selected.length === 1) {
        selectedPort = selected[0];
        canonical = selected[0] === ports[0];
      }
    } catch {
      // The guest router remains the source of truth for numeric HTTP routes.
    }
  }
  if (selectedPort && !['', 'http', 'https'].includes(applicationProtocol(selectedPort))) {
    return routeError(`Unsupported Compose application protocol: ${applicationProtocol(selectedPort)}`);
  }
  if (isApplicationStopped(service)) {
    const start = startApplication(service, env);
    ctx.waitUntil(start.promise);
    return applicationStarting(request, service, start.error);
  }
  if (service.state === 'restarting') return applicationStarting(request, service);
  if (service.state && service.state !== 'running') {
    return routeError('Container is not available for application routing', 503);
  }
  if (selectedPort) {
    const response = await protocolResponse(request, service, selectedPort, env, canonical);
    if (response) return response;
  }
  headers.set(targetHeader, String(target));
  headers.set(containerHeader, service.id);
  headers.set(publishedHeader, String(published));
  headers.set('x-xe-origin-proto', url.protocol === 'https:' ? 'https' : 'http');
  headers.set('x-xe-public-host', url.host);
  // The guest router speaks HTTP on its private Unix socket even when the
  // public connection was terminated as HTTPS by the host.
  url.protocol = 'http:';
  url.port = '';
  const response = await env.ROUTER.fetch(new Request(url, {
    method: request.method, headers, body: request.body, redirect: 'manual',
  }));
  if (response.headers.get('x-xe-router-unavailable') === 'true') {
    invalidateApplicationService(service, env);
    const start = applicationStart(service);
    if (start) return applicationStarting(request, service, start.error);
  }
  if (response.status < 500) applicationReady(service);
  return response;
}
