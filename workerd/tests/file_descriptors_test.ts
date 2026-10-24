import assert from 'node:assert/strict';
import management from '../management.js';

Deno.test('descriptor telemetry requests only the selected container and never forwards credentials', async () => {
  const requests: string[] = [];
  const id = 'a'.repeat(64);
  const env = {
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({ phase: 'healthy', message: 'Ready' })) },
    MAINTENANCE: { fetch: (input: string, options: RequestInit) => {
      requests.push(input);
      assert.equal(options.method, 'GET');
      assert.equal(options.headers, undefined);
      return Promise.resolve(Response.json({ vm: { used: 1, limit: 100 }, processes: [] }));
    } }
  };
  for (const suffix of ['', '?container=' + id]) {
    const response = await management.fetch(new Request('http://compose-ui.localhost/v1.24/file-descriptors' + suffix,
      { headers: { Cookie: 'private', Authorization: 'private' } }), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.equal((await response.json()).vm.used, 1);
  }
  assert.deepEqual(requests, ['http://maintenance/file-descriptors', 'http://maintenance/file-descriptors?container=' + id]);
});

Deno.test('descriptor scans reject arbitrary targets and cross-site requests before querying the VM', async () => {
  let reads = 0;
  const env = { RUNTIME_STATUS: { fetch: () => { reads++; return Promise.resolve(Response.json({ phase: 'healthy', message: 'Ready' })); } } };
  const base = 'http://compose-ui.localhost/v1.24/file-descriptors';
  for (const suffix of ['?container=bad', '?pid=1', '?container=', '?container=' + 'a'.repeat(64) + '&container=' + 'b'.repeat(64)]) {
    assert.equal((await management.fetch(new Request(base + suffix), env)).status, 400);
  }
  assert.equal((await management.fetch(new Request(base, { method: 'POST' }), env)).status, 405);
  assert.equal((await management.fetch(new Request(base, { headers: { Origin: 'https://evil.test' } }), env)).status, 403);
  assert.equal((await management.fetch(new Request(base, { headers: { 'Sec-Fetch-Site': 'cross-site' } }), env)).status, 403);
  assert.equal(reads, 0);
});

Deno.test('stopped VMs are not scanned and missing telemetry is reported unavailable', async () => {
  const base = 'http://compose-ui.localhost/v1.24/file-descriptors';
  let scans = 0;
  const env = {
    RUNTIME_STATUS: { fetch: () => Promise.resolve(Response.json({ phase: 'stopped', message: 'Stopped' })) },
    MAINTENANCE: { fetch: () => { scans++; throw new Error('Unavailable'); } }
  };
  assert.equal((await management.fetch(new Request(base), env)).status, 503);
  assert.equal(scans, 0);
  env.RUNTIME_STATUS.fetch = () => Promise.resolve(Response.json({ phase: 'healthy', message: 'Ready' }));
  assert.equal((await management.fetch(new Request(base), env)).status, 503);
  assert.equal(scans, 1);
});
