export async function readAppPorts(env) {
  try {
    const response = await env.RUNTIME_STATUS.fetch('http://status/app-ports.json');
    if (!response.ok) return null;
    const ports = await response.json();
    if (!Number.isInteger(ports.http) || !Number.isInteger(ports.https) ||
        ports.http < 1 || ports.http > 65535 || ports.https < 1 || ports.https > 65535 ||
        ports.http === ports.https || ports.http === 8094 || ports.https === 8094) {
      return null;
    }
    return { http: ports.http, https: ports.https, publicHttpReady: ports.publicHttpReady !== false };
  } catch {
    return null;
  }
}
