import assert from 'node:assert/strict';
import { createDiskUsageService, summarizeDiskUsage } from '../disk-usage.js';
import management from '../management.js';

Deno.test('inventory never requests filesystem sizes and shares concurrent reads for one minute', async () => {
  let now = 1000;
  const paths: string[] = [];
  const service = createDiskUsageService({ fetch: async (input: string) => {
    const url = new URL(input);
    paths.push(url.pathname + url.search);
    if (url.pathname === '/images/json') return Response.json([{ Id: 'used' }, { Id: 'unused' }]);
    if (url.pathname === '/containers/json') return Response.json([
      { Id: 'running', State: 'running', ImageID: 'used', Mounts: [{ Type: 'volume', Name: 'db' }] },
      { Id: 'stopped', State: 'exited', ImageID: 'used', Mounts: [{ Type: 'volume', Name: 'db' }] },
    ]);
    return Response.json({ Volumes: [{ Name: 'db', Driver: 'local' }, { Name: 'old-db', Driver: 'local' }] });
  } }, { now: () => now });
  const responses = await Promise.all([service.response(false), service.response(false)]);
  const inventory = (await responses[0].json()).inventory;
  assert.equal(inventory.unusedImageCount, 1);
  assert.equal(inventory.stoppedContainerCount, 1);
  assert.deepEqual(inventory.volumes.map((row: { references: number }) => row.references), [2, 0]);
  assert.equal(paths.length, 3);
  assert(paths.includes('/containers/json?all=true&size=false'));
  now += 59_000;
  await service.response(false);
  assert.equal(paths.length, 3);
  now += 1000;
  await service.response(false);
  assert.equal(paths.length, 6);
  assert(!paths.includes('/system/df'));
});

Deno.test('explicit scans share a request and reuse results for five minutes', async () => {
  let now = 1000;
  let reads = 0;
  const service = createDiskUsageService({ fetch: async (input: string) => {
    assert.equal(new URL(input).pathname, '/system/df');
    reads++;
    return Response.json({ LayersSize: 42 });
  } }, { now: () => now });
  const responses = await Promise.all([service.response(true), service.response(true)]);
  assert.equal(reads, 1);
  assert.equal((await responses[0].json()).report.categories[0].totalBytes, 42);
  now += 299_999;
  await service.response(true);
  assert.equal(reads, 1);
  now++;
  await service.response(true);
  assert.equal(reads, 2);
});

Deno.test('timed out scans abort Docker and throttle retries', async () => {
  let reads = 0;
  const service = createDiskUsageService({ fetch: (_input: string, init: RequestInit) => {
    reads++;
    return new Promise((_resolve, reject) => init.signal!.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  } }, { scanTimeoutMs: 1 });
  const response = await service.response(true);
  assert.equal(response.status, 503);
  assert.match((await response.json()).message, /exceeded 60 seconds/);
  await service.response(true);
  assert.equal(reads, 1);
});

Deno.test('reclaim estimates exclude shared layers, running containers and unknown sizes', () => {
  const report = summarizeDiskUsage({
    LayersSize: 100,
    Images: [{ Id: 'sha256:image', Size: 100, SharedSize: 80, Containers: 0 }],
    Containers: [{ Id: 'running', State: 'running', SizeRw: 30 }, { Id: 'stopped', State: 'exited', SizeRw: 5 }],
    Volumes: [{ Name: 'old-db', UsageData: { RefCount: 0, Size: 10 } }, { Name: 'unknown', UsageData: { RefCount: 0, Size: -1 } }],
    BuildCache: [{ ID: 'shared', Size: 80, Shared: true, InUse: false }, { ID: 'unique', Size: 7, Shared: false, InUse: false }],
  }, 'now');
  assert.equal(report.categories[0].reclaimableBytes, 20);
  assert.equal(report.categories[1].totalBytes, 35);
  assert.equal(report.categories[1].reclaimableBytes, 5);
  assert.equal(report.categories[2].totalBytes, undefined);
  assert.equal(report.categories[2].reclaimableBytes, undefined);
  assert.equal(report.categories[3].reclaimableBytes, 7);
});

Deno.test('disk routes require the right method and reject cross-site scan triggers', async () => {
  let reads = 0;
  const env = {
    DOCKER: { fetch: () => { reads++; return Promise.resolve(Response.json({ LayersSize: 0 })); } },
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({ phase: 'healthy', message: 'Ready' })) },
  };
  const url = 'http://compose-ui.localhost/v1.24/disk-usage/scan';
  assert.equal((await management.fetch(new Request(url), env)).status, 405);
  assert.equal((await management.fetch(new Request(url, { method: 'POST', headers: { Origin: 'https://evil.test' } }), env)).status, 403);
  assert.equal((await management.fetch(new Request(url, { method: 'POST', headers: { 'Sec-Fetch-Site': 'cross-site' } }), env)).status, 403);
  assert.equal(reads, 0);
  assert.equal((await management.fetch(new Request(url, { method: 'POST' }), env)).status, 200);
  assert.equal(reads, 1);
});

Deno.test('cleanup proxies only fixed host operations and rejects cross-site requests', async () => {
  const operations: string[] = [];
  const env = {
    DOCKER: {},
    MAINTENANCE: { fetch: (input: string, init: RequestInit) => {
      operations.push(`${init.method} ${new URL(input).pathname}`);
      return Promise.resolve(Response.json({ running: init.method === 'POST', results: [] }, { status: init.method === 'POST' ? 202 : 200 }));
    } },
  };
  const url = 'http://compose-ui.localhost/v1.24/disk-usage/cleanup';
  assert.equal((await management.fetch(new Request(url, { method: 'DELETE' }), env)).status, 405);
  assert.equal((await management.fetch(new Request(url, { method: 'POST', headers: { Origin: 'https://evil.test' } }), env)).status, 403);
  assert.equal((await management.fetch(new Request(url, { method: 'POST', headers: { 'Sec-Fetch-Site': 'cross-site' } }), env)).status, 403);
  assert.equal(operations.length, 0);
  assert.equal((await management.fetch(new Request(url), env)).status, 200);
  assert.equal((await management.fetch(new Request(url, { method: 'POST', body: '{"command":"anything"}' }), env)).status, 202);
  assert.deepEqual(operations, ['GET /status', 'POST /cleanup']);
});

Deno.test('cleanup refreshes cached disk data without invalidating on every status poll', async () => {
  let inventoryReads = 0;
  let scanReads = 0;
  const completedAt = '2026-10-04T06:05:19Z';
  const env = {
    DOCKER: { fetch: (input: string) => {
      const path = new URL(input).pathname;
      if (path === '/system/df') {
        scanReads++;
        return Promise.resolve(Response.json({ LayersSize: 42 }));
      }
      inventoryReads++;
      return Promise.resolve(Response.json(path === '/volumes' ? { Volumes: [] } : []));
    } },
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({ phase: 'healthy', message: 'Ready' })) },
    MAINTENANCE: { fetch: (_input: string, init: RequestInit) => Promise.resolve(Response.json({
      running: init.method === 'POST', completedAt, results: [],
    }, { status: init.method === 'POST' ? 202 : 200 })) },
  };
  const base = 'http://compose-ui.localhost/v1.24/disk-usage';
  const request = (suffix = '', method = 'GET') => management.fetch(new Request(base + suffix, { method }), env);
  assert.equal((await request('/scan', 'POST')).status, 200);
  assert.equal((await (await request()).json()).report.categories[0].totalBytes, 42);
  assert.equal(inventoryReads, 3);
  assert.equal(scanReads, 1);

  assert.equal((await request('/cleanup')).status, 200);
  assert.equal((await (await request()).json()).report, undefined);
  assert.equal(inventoryReads, 6);
  assert.equal((await request('/cleanup')).status, 200);
  await request();
  assert.equal(inventoryReads, 6);

  assert.equal((await request('/scan', 'POST')).status, 200);
  assert.equal(scanReads, 2);
  assert.equal((await request('/cleanup', 'POST')).status, 202);
  assert.equal((await (await request()).json()).report, undefined);
  assert.equal(inventoryReads, 9);
  assert.equal((await request('/scan', 'POST')).status, 200);
  assert.equal(scanReads, 3);
});
