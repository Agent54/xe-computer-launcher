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

export async function runtimeUnavailable(env, status = 503, knownRuntime) {
  let runtime = knownRuntime || await readRuntimeStatus(env);
  if (runtime.phase === 'healthy') runtime = {
    ...runtime,
    message: 'Container services are unavailable. Xe Launcher will reconnect automatically.',
    reason: 'container_services_unavailable',
  };
  return Response.json({
    ok: false,
    error: runtime.reason === 'oom' ? 'container_runtime_oom' : 'container_runtime_unavailable',
    message: runtime.message,
    runtime,
  }, { status, headers: { 'Cache-Control': 'no-store', 'Retry-After': '2' } });
}

export async function surfaceRuntimeFailure(response, env) {
  if (response.status < 500) return response;
  const runtime = await readRuntimeStatus(env);
  return runtime.phase === 'healthy' ? response : runtimeUnavailable(env, 503, runtime);
}
