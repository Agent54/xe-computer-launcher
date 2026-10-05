import { invalidateApplicationService } from './app-discovery.js';
import { startupResponse } from './startup-response.js';

const startupResponses = new WeakSet();
const startable = new Set(['uncreated', 'created', 'exited', 'stopped']);
// Coalesce readiness acknowledgements; normal app traffic does not need an
// extra coordinator request on every response. Container starts stay central.
const readyReports = new WeakMap();

function readinessKey(service) {
  return JSON.stringify([service.id, service.project, service.configFiles, service.service, service.number]);
}

function clearReadiness(service, env) {
  readyReports.get(env.STARTUP)?.delete(readinessKey(service));
}

export function isApplicationStopped(service) {
  return startable.has(service.state);
}

async function coordinatorRequest(path, service, env) {
  const response = await env.STARTUP.fetch(new Request(`http://startup${path}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ project: service.project, service: service.service,
      id: service.id, configFiles: service.configFiles, number: service.number }),
  }));
  if (!response.ok) throw new Error('Application startup coordinator is unavailable.');
  return response.status === 204 ? null : await response.json();
}

export async function applicationStart(service, env) {
  const entry = await coordinatorRequest('/status', service, env);
  if (entry) clearReadiness(service, env);
  return entry;
}

export async function startApplication(service, env) {
  clearReadiness(service, env);
  const entry = await coordinatorRequest('/start', service, env);
  if (entry.pending) {
    entry.promise = coordinatorRequest('/wait', service, env).then(result => {
      if (result) Object.assign(entry, result);
      else entry.pending = false;
      invalidateApplicationService(service, env);
    });
  } else {
    entry.promise = Promise.resolve();
    if (!entry.message) invalidateApplicationService(service, env);
  }
  return entry;
}

export async function applicationReady(service, env) {
  let reports = readyReports.get(env.STARTUP);
  if (!reports) { reports = new Map(); readyReports.set(env.STARTUP, reports); }
  const key = readinessKey(service);
  if (reports.get(key) > Date.now()) return;
  for (const [key, expires] of reports) if (expires <= Date.now()) reports.delete(key);
  if (reports.size >= 128) reports.delete(reports.keys().next().value);
  reports.set(key, Date.now() + 120_000);
  try { await coordinatorRequest('/ready', service, env); }
  catch (error) { reports.delete(key); throw error; }
}

export function isApplicationStartupResponse(response) {
  return startupResponses.has(response);
}

export function applicationStarting(request, service, failed = false, startingMessage = 'Starting…') {
  const message = failed ? typeof failed === 'string' ? failed
    : 'Could not start this app. Try again or check its logs in Compose.' : startingMessage;
  const response = startupResponse(request, {
    name: service.service, message, failed: Boolean(failed),
    payload: { app: service.service, state: failed ? 'failed' : 'starting', message },
  });
  startupResponses.add(response);
  return response;
}
