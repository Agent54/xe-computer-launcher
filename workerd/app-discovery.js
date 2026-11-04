// Compose owns service discovery for every lifecycle state. The guest only
// validates the selected container and resolves its current network address.
const catalogues = new WeakMap();
const cacheLifetime = 100;
const discoveryTimeout = 5000;

function catalogue(env) {
  let cache = catalogues.get(env.COMPOSE);
  if (!cache) {
    cache = new Map();
    catalogues.set(env.COMPOSE, cache);
  }
  return cache;
}

async function cached(cache, key, read) {
  const entry = cache.get(key);
  if (entry && entry.expires > Date.now()) return entry.value;
  // Workerd I/O and promise continuations belong to the creating request.
  // Share only parsed snapshots; concurrent misses must own their own reads.
  const requestedAt = Date.now();
  const controller = new AbortController();
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      const error = new Error('Compose discovery timed out');
      reject(error);
      controller.abort(error);
    }, discoveryTimeout);
  });
  try {
    const value = await Promise.race([read(controller.signal), timeout]);
    for (const [key, entry] of cache) if (entry.expires <= Date.now()) cache.delete(key);
    const expires = requestedAt + cacheLifetime;
    if (expires > Date.now()) {
      if (cache.size >= 128) cache.delete(cache.keys().next().value);
      cache.set(key, { value, expires });
    }
    return value;
  } finally {
    clearTimeout(timer);
    controller.abort();
  }
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

function configKey(files) {
  return files.split(',').map(file => file.trim().replaceAll('\\', '/')).filter(Boolean).sort().join(',');
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
  return await cached(catalogue(env), variantKey(variant), async signal => {
    const psURL = new URL(`http://compose/v1.24/ps/${encodeURIComponent(variant.project)}`);
    psURL.searchParams.set('all', 'true');
    const configURL = new URL(`http://compose/v1.24/config/${encodeURIComponent(variant.project)}`);
    configURL.searchParams.set('format', 'json');
    if (variant.configFiles) {
      psURL.searchParams.set('path', variant.configFiles);
      configURL.searchParams.set('path', variant.configFiles);
    }
    const [rows, config] = await Promise.all([
      env.COMPOSE.fetch(psURL.href, { signal }).then(async response => {
        if (!response.ok) throw new Error('Compose service discovery unavailable');
        const rows = await response.json();
        if (!Array.isArray(rows)) throw new Error('Invalid Compose service list');
        return rows;
      }),
      // Numeric routes can still use ps bindings when configuration is unavailable.
      env.COMPOSE.fetch(configURL.href, { signal }).then(response => response.ok ? response.json() : null).catch(() => null),
    ]);
    return rows.filter(row => row.Service && row.Labels?.['com.docker.compose.oneoff']?.toLowerCase() !== 'true')
      // Compose ps is project-scoped and can return a container belonging to a
      // different checkout. Only its owning variant may supply its port config.
      .filter(row => !row.ID || !variant.configFiles || !row.Labels?.['com.docker.compose.project.config_files'] ||
        configKey(row.Labels['com.docker.compose.project.config_files']) === configKey(variant.configFiles))
      .map(row => serviceDetails(row, variant, config));
  });
}

export async function resolveApplicationService(name, env) {
  const projects = await cached(catalogue(env), 'projects', async signal => {
    const response = await env.COMPOSE.fetch('http://compose/v1.24/ls?all=true', { signal });
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
