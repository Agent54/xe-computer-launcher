// Share an in-flight start between requests for any port of the same container.
const starts = new Map();
const startupWindow = 120_000;
const startable = new Set(['created', 'exited', 'stopped']);

export function isApplicationStopped(service) {
  return startable.has(service.state);
}

export function applicationStart(service) {
  const entry = starts.get(service.id);
  if (entry && !entry.pending && entry.expires <= Date.now()) {
    starts.delete(service.id);
    return undefined;
  }
  return entry;
}

export function startApplication(service, env) {
  let entry = applicationStart(service);
  if (entry) return entry;
  for (const [id, value] of starts) {
    if (!value.pending && value.expires <= Date.now()) starts.delete(id);
  }
  entry = { pending: true, error: false, expires: Infinity, promise: null };
  starts.set(service.id, entry);
  entry.promise = (async () => {
    try {
      const response = await env.COMPOSE.fetch(new Request(
        `http://compose/v1.24/start/${encodeURIComponent(service.project)}/container`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ container: service.id, ...(service.configFiles ? { path: service.configFiles } : {}) }),
          signal: AbortSignal.timeout(60_000),
        }));
      if (!response.ok) throw new Error('Container start failed');
      await response.arrayBuffer();
    } catch {
      entry.error = true;
    } finally {
      entry.pending = false;
      entry.expires = Date.now() + (entry.error ? 10_000 : startupWindow);
    }
  })();
  return entry;
}

export function applicationReady(service) {
  starts.delete(service.id);
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
  const message = failed ? 'Could not start this app. Try again or check its logs in Compose.' : 'Starting…';
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
    p { margin: 12px 0 0; color: var(--muted); font-size: 14px; line-height: 1.6; }
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
    <p role="status">${message}</p>
    ${failed ? '<a href="">Try again</a>' : ''}
  </main>
</body>
</html>`, { status: 503, headers });
}
