export const fallbackAppPorts = Object.freeze({ http: 5196, https: 5194 });

export async function readAppPorts(env) {
  try {
    const response = await env.RUNTIME_STATUS.fetch('http://status/app-ports.json');
    if (!response.ok) return fallbackAppPorts;
    const ports = await response.json();
    if (!Number.isInteger(ports.http) || !Number.isInteger(ports.https) ||
        ports.http < 1 || ports.http > 65535 || ports.https < 1 || ports.https > 65535 ||
        ports.http === ports.https || ports.http === 8094 || ports.https === 8094) {
      return fallbackAppPorts;
    }
    return { http: ports.http, https: ports.https };
  } catch {
    return fallbackAppPorts;
  }
}
