import { invalidateApplicationService } from './app-discovery.js';

// Share an in-flight start between requests for any port of the same container.
const starts = new Map();
const startupWindow = 120_000;
const startable = new Set(['uncreated', 'created', 'exited', 'stopped']);

function serviceKey(service) {
  return JSON.stringify([service.project, service.configFiles || '', service.service, Number(service.number) || 1]);
}

export function isApplicationStopped(service) {
  return startable.has(service.state);
}

export function applicationStart(service) {
  const key = service.id && starts.has(service.id) ? service.id : serviceKey(service);
  const entry = starts.get(key);
  if (entry && !entry.pending && entry.expires <= Date.now()) {
    starts.delete(key);
    return undefined;
  }
  return entry;
}

async function startError(response) {
  const body = await response.text();
  let detail;
  try {
    const result = JSON.parse(body);
    detail = typeof result.error === 'string' ? result.error : result.message;
  } catch {
    if (response.headers.get('content-type')?.startsWith('text/plain')) detail = body;
  }
  detail = typeof detail === 'string' ? detail.trim().slice(0, 2000) : '';
  return new Error(`Compose returned HTTP ${response.status}${detail ? `: ${detail}` : ' while starting this app.'}`);
}

export function startApplication(service, env) {
  let entry = applicationStart(service);
  if (entry) return entry;
  for (const [id, value] of starts) {
    if (!value.pending && value.expires <= Date.now()) starts.delete(id);
  }
  entry = { pending: true, error: false, expires: Infinity, promise: null };
  starts.set(service.id || serviceKey(service), entry);
  entry.promise = (async () => {
    try {
      const response = await env.COMPOSE.fetch(new Request(
        `http://compose/v1.24/start/${encodeURIComponent(service.project)}/container`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ ...(service.id ? { container: service.id } : { service: service.service }),
            ...(service.configFiles ? { path: service.configFiles } : {}) }),
          signal: AbortSignal.timeout(service.id ? 60_000 : 600_000),
        }));
      if (!response.ok) throw await startError(response);
      await response.arrayBuffer();
    } catch (error) {
      entry.error = error?.name === 'TimeoutError' ? 'Starting this app timed out.'
        : error?.message || 'Could not start this app.';
      console.warn('Application start failed:', service.project, service.service, entry.error);
    } finally {
      entry.pending = false;
      entry.expires = Date.now() + (entry.error ? 10_000 : startupWindow);
      invalidateApplicationService(service, env);
    }
  })();
  return entry;
}

export function applicationReady(service) {
  starts.delete(service.id);
  starts.delete(serviceKey(service));
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  })[char]);
}

export function applicationStarting(request, service, failed = false) {
  const headers = {
    'Cache-Control': 'no-store',
    'Retry-After': '2',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
  };
  const message = failed ? typeof failed === 'string' ? failed
    : 'Could not start this app. Try again or check its logs in Compose.' : 'Starting…';
  // API calls and upgrades receive a retryable response; never replay a POST.
  if (!['GET', 'HEAD'].includes(request.method) || request.headers.has('upgrade') ||
      (request.headers.has('accept') && !request.headers.get('accept').includes('text/html') &&
       !request.headers.get('accept').includes('*/*'))) {
    return Response.json({ app: service.service, state: failed ? 'failed' : 'starting', message }, { status: 503, headers });
  }
  headers['Content-Type'] = 'text/html; charset=utf-8';
  headers['Content-Security-Policy'] = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'";
  const name = escapeHTML(service.service);
  return new Response(request.method === 'HEAD' ? null : `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  ${failed ? '' : '<meta http-equiv="refresh" content="2">'}
  <title>${name} · ${failed ? 'Unable to start' : 'Starting'}</title>
  <style>
    :root { color-scheme: dark; --background: #000000; --text: #f5f5f5; --muted: #a3a3a3; --track: #262626; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; min-height: 100svh; display: grid; place-items: center; padding: 32px; background: var(--background); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    main { width: min(100%, 400px); text-align: center; }
    .loader { width: 28px; height: 28px; margin: 0 auto 28px; border: 2px solid var(--track); border-top-color: var(--text); border-radius: 50%; animation: spin 1s linear infinite; }
    h1 { margin: 0; font-size: clamp(24px, 5vw, 32px); font-weight: 500; letter-spacing: -.03em; overflow-wrap: anywhere; }
    p { margin: 12px 0 0; color: var(--muted); font-size: 14px; line-height: 1.6; white-space: pre-wrap; overflow-wrap: anywhere; }
    a { display: inline-block; margin-top: 24px; color: var(--text); text-underline-offset: 4px; }
    a:focus-visible { outline: 2px solid var(--text); outline-offset: 6px; }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (prefers-reduced-motion: reduce) { .loader { animation: none; } }
  </style>
</head>
<body>
  <main aria-busy="${!failed}" aria-live="polite">
    ${failed ? '' : '<div class="loader" aria-hidden="true"></div>'}
    <h1>${name}</h1>
    <p role="status">${escapeHTML(message)}</p>
    ${failed ? '<a href="">Try again</a>' : ''}
  </main>
</body>
</html>`, { status: 503, headers });
}
