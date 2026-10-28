const frontendOrigin = 'https://chrome-devtools-frontend.appspot.com';

export function allowCDPConnection(policy, url) {
  return policy.replace(/(^|;)(\s*connect-src\b[^;]*)/i, `$1$2 wss://${url.host}`);
}

export async function serveCDPFrontend(path, url, env) {
  const upstreamPath = /^\/frontend(\/serve_rev\/@[a-f0-9]+\/[a-zA-Z0-9_./-]+)$/i.exec(path)?.[1];
  if (!upstreamPath) return new Response('Not found', { status: 404 });
  try {
    // Only the fixed upstream and asset path are forwarded, never local query
    // parameters, cookies or credentials from the inspector request.
    const upstream = await env.DEVTOOLS_FRONTEND.fetch(new Request(`${frontendOrigin}${upstreamPath}`, {
      redirect: 'manual',
    }));
    if (!upstream.ok) {
      await upstream.body?.cancel();
      return new Response('DevTools frontend unavailable', { status: upstream.status === 404 ? 404 : 502 });
    }
    const headers = new Headers({
      'Content-Type': upstream.headers.get('Content-Type') || 'application/octet-stream',
      'Cache-Control': upstream.headers.get('Cache-Control') || 'no-cache',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    });
    const policy = upstream.headers.get('Content-Security-Policy');
    if (policy) headers.set('Content-Security-Policy', allowCDPConnection(policy, url));
    const response = new Response(upstream.body, { headers });
    if (!headers.get('Content-Type').toLowerCase().includes('text/html')) return response;
    headers.set('Cache-Control', 'no-store');
    return new HTMLRewriter().on('meta', { element(element) {
      if (element.getAttribute('http-equiv')?.toLowerCase() !== 'content-security-policy') return;
      const policy = element.getAttribute('content');
      if (policy) element.setAttribute('content', allowCDPConnection(policy, url));
    } }).transform(new Response(response.body, { headers }));
  } catch {
    return new Response('DevTools frontend unavailable', { status: 502 });
  }
}
