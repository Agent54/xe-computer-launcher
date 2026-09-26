// Compose owns service discovery for every lifecycle state. The guest only
// validates the selected container and resolves its current network address.
const catalogues = new WeakMap();
const cacheLifetime = 100;

function catalogue(env) {
  let cache = catalogues.get(env.COMPOSE);
  if (!cache) {
    cache = new Map();
    catalogues.set(env.COMPOSE, cache);
  }
  return cache;
}

async function cached(cache, key, read) {
  let entry = cache.get(key);
  if (!entry || entry.expires <= Date.now()) {
    for (const [key, value] of cache) if (value.expires <= Date.now()) cache.delete(key);
    if (cache.size >= 128) cache.delete(cache.keys().next().value);
    entry = { expires: Infinity, promise: null };
    cache.set(key, entry);
    const requestedAt = Date.now();
    entry.promise = read().then(value => {
      entry.expires = requestedAt + cacheLifetime;
      return value;
    }).catch(error => {
      if (cache.get(key) === entry) cache.delete(key);
      throw error;
    });
  }
  return entry.promise;
}

function projectVariants(project) {
  const grouped = new Map();
  for (const file of (project.ConfigFiles || '').split(',').map(file => file.trim()).filter(Boolean)) {
    const normalized = file.replaceAll('\\', '/');
    const directory = normalized.slice(0, normalized.lastIndexOf('/'));
    if (!grouped.has(directory)) grouped.set(directory, []);
    grouped.get(directory).push(file);
  }
  return (grouped.size ? [...grouped.values()] : [[]]).map(files => ({
    project: project.Name, configFiles: files.join(','),
  }));
}

function variantKey(service) {
  return JSON.stringify([service.project, service.configFiles]);
}

export function invalidateApplicationService(service, env) {
  catalogue(env).delete(variantKey(service));
}

function validPort(port) {
  return Number.isInteger(port) && port > 0 && port < 65536;
}

function serviceDetails(row, variant, config) {
  const labelledNumber = Number(row.Labels?.['com.docker.compose.container-number']);
  const number = Number.isInteger(labelledNumber) && labelledNumber > 0 ? labelledNumber :
    Number(/[-_](\d+)$/.exec(row.Name || '')?.[1]) || 1;
  const ports = config ? config.services?.[row.Service]?.ports || [] : null;
  let publishedPorts = (row.Publishers || []).filter(port => port.Protocol === 'tcp' &&
    validPort(port.TargetPort) && validPort(port.PublishedPort))
    .map(port => ({ target: port.TargetPort, published: port.PublishedPort }));
  // Docker's ps data omits bindings while a container is stopped. Configured
  // ports allow startup; the guest rechecks actual bindings before forwarding.
  if (row.State !== 'running' && !publishedPorts.length) {
    publishedPorts = (ports || []).filter(port => (port.protocol || 'tcp') === 'tcp' &&
      validPort(port.target) && validPort(Number(port.published)))
      .map(port => ({ target: port.target, published: Number(port.published) }));
  }
  return { ...variant, service: row.Service, number, id: row.ID || undefined,
    state: row.State, ports, publishedPorts };
}

async function discoverVariant(variant, env) {
  return await cached(catalogue(env), variantKey(variant), async () => {
    const psURL = new URL(`http://compose/v1.24/ps/${encodeURIComponent(variant.project)}`);
    psURL.searchParams.set('all', 'true');
    const configURL = new URL(`http://compose/v1.24/config/${encodeURIComponent(variant.project)}`);
    configURL.searchParams.set('format', 'json');
    if (variant.configFiles) {
      psURL.searchParams.set('path', variant.configFiles);
      configURL.searchParams.set('path', variant.configFiles);
    }
    const [rows, config] = await Promise.all([
      env.COMPOSE.fetch(psURL.href).then(async response => {
        if (!response.ok) throw new Error('Compose service discovery unavailable');
        const rows = await response.json();
        if (!Array.isArray(rows)) throw new Error('Invalid Compose service list');
        return rows;
      }),
      // Numeric routes can still use ps bindings when configuration is unavailable.
      env.COMPOSE.fetch(configURL.href).then(response => response.ok ? response.json() : null).catch(() => null),
    ]);
    return rows.filter(row => row.Service && row.Labels?.['com.docker.compose.oneoff']?.toLowerCase() !== 'true')
      .map(row => serviceDetails(row, variant, config));
  });
}

export async function resolveApplicationService(name, env) {
  const projects = await cached(catalogue(env), 'projects', async () => {
    const response = await env.COMPOSE.fetch('http://compose/v1.24/ls?all=true');
    if (!response.ok) throw new Error('Compose discovery unavailable');
    const projects = await response.json();
    if (!Array.isArray(projects)) throw new Error('Invalid Compose project list');
    return projects;
  });
  const variants = projects.flatMap(projectVariants);
  const services = [];
  for (let offset = 0; offset < variants.length; offset += 8) {
    services.push(...(await Promise.all(variants.slice(offset, offset + 8)
      .map(variant => discoverVariant(variant, env)))).flat());
  }
  const matches = services.filter(service => {
    const suffix = service.number > 1 ? `_${service.number}` : '';
    return name === `${service.service}${suffix}` || name === `${service.service}_${service.project}${suffix}`;
  });
  return matches.length === 1 ? matches[0] : new Response(
    matches.length ? 'Ambiguous service; include its project name.' : 'Service not found', {
      status: 404, headers: { 'Cache-Control': 'no-store' },
    });
}
