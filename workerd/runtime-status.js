import { startupResponse } from './startup-response.js';

const fallback = Object.freeze({
  phase: 'degraded',
  message: 'Container runtime is unavailable. Xe Launcher will retry automatically.',
  reason: 'docker_unavailable',
});

export async function readRuntimeStatus(env) {
  try {
    const response = await env.RUNTIME_STATUS.fetch('http://status/status.json');
    if (!response.ok) return fallback;
    const status = await response.json();
    if (!status || typeof status.phase !== 'string' || typeof status.message !== 'string') return fallback;
    return status;
  } catch {
    return fallback;
  }
}

export async function runtimeUnavailable(env, { request, status = 503, runtime: knownRuntime } = {}) {
  let runtime = knownRuntime || await readRuntimeStatus(env);
  if (runtime.phase === 'healthy') runtime = {
    ...runtime,
    message: 'Container services are unavailable. Xe Launcher will reconnect automatically.',
    reason: 'container_services_unavailable',
  };
  const payload = {
    ok: false,
    error: runtime.reason === 'oom' ? 'container_runtime_oom' : 'container_runtime_unavailable',
    message: runtime.message,
    runtime,
  };
  return startupResponse(request, {
    name: 'Container runtime', message: runtime.message,
    failed: ['failed', 'stopped'].includes(runtime.phase), payload, status,
  });
}

export async function surfaceRuntimeFailure(response, env, request) {
  if (response.status < 500) return response;
  const runtime = await readRuntimeStatus(env);
  return runtime.phase === 'healthy' ? response : runtimeUnavailable(env, { request, runtime });
}
