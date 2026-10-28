import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import { applicationStarting } from '../app-startup.js';
import { startupResponse } from '../startup-response.js';

const service = { service: 'web', state: 'restarting' };
const navigation = () => new Request('https://web.app.localhost/', { headers: { Accept: 'text/html' } });

Deno.test('restart-loop placeholders expose the current state in HTML and existing JSON responses', async () => {
  const response = applicationStarting(navigation(), service);
  const html = await response.text();
  assert.match(html, /<title>web · Restarting<\/title>/);
  assert.match(html, /role="status">Restarting…<\/p>/);
  assert.match(html, /type="button">Cancel<\/button>/);
  assert.doesNotMatch(html, /http-equiv="refresh"/);
  const [, nonce] = html.match(/<script nonce="([^"]+)">/) ?? [];
  assert(nonce);
  assert.match(response.headers.get('content-security-policy')!, new RegExp(`script-src 'nonce-${nonce}'`));
  const json = await applicationStarting(new Request('https://web.app.localhost/', {
    headers: { Accept: 'application/json' },
  }), service).json();
  assert.deepEqual(json, { app: 'web', state: 'restarting', message: 'Restarting…' });
});

Deno.test('Cancel stops the reload timer and all later retry requests without calling an API', async () => {
  const html = await applicationStarting(navigation(), service).text();
  const [, script] = html.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/) ?? [];
  assert(script);
  const elements = new Map<string, { hidden: boolean; disabled: boolean; textContent: string;
    attributes: Map<string, string>; setAttribute(name: string, value: string): void;
    addEventListener(name: string, listener: () => void): void }>();
  let cancel: (() => void) | undefined;
  let retry: (() => void) | undefined;
  let cleared = false;
  let reloads = 0;
  for (const id of ['startup-main', 'startup-spinner', 'startup-status', 'startup-cancel']) {
    elements.set(id, { hidden: false, disabled: false, textContent: '', attributes: new Map(),
      setAttribute(name, value) { this.attributes.set(name, value); },
      addEventListener(name, listener) { assert.equal(name, 'click'); cancel = listener; } });
  }
  // Only the page's DOM and reload timer are available: any fetch/API call fails.
  runInNewContext(script, {
    document: { getElementById: (id: string) => elements.get(id) },
    window: { location: { reload: () => { reloads++; } } },
    setTimeout(callback: () => void, delay: number) { assert.equal(delay, 2000); retry = callback; return 1; },
    clearTimeout(timer: number) { assert.equal(timer, 1); cleared = true; },
  });
  assert(retry && cancel);
  retry();
  assert.equal(reloads, 1, 'the pending page normally retries after two seconds');
  cancel();
  assert(cleared);
  retry();
  assert.equal(reloads, 1, 'even an already queued timer cannot reload after Cancel');
  assert.equal(elements.get('startup-main')!.attributes.get('aria-busy'), 'false');
  assert.equal(elements.get('startup-spinner')!.hidden, true);
  assert.equal(elements.get('startup-cancel')!.disabled, true);
  assert.equal(elements.get('startup-cancel')!.textContent, 'Cancelled');
  assert.match(elements.get('startup-status')!.textContent, /Automatic retry cancelled/);
});

Deno.test('failed placeholders have no retry script or Cancel and keep errors escaped', async () => {
  const html = await applicationStarting(navigation(), service, '<script>alert(1)</script>').text();
  assert.doesNotMatch(html, /<script|startup-cancel|http-equiv="refresh"/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
  assert.match(html, /Try again/);
});

Deno.test('runtime recovery placeholders also show Restarting and HEAD responses remain empty', async () => {
  const body = { name: 'Container runtime', message: 'Recovering…', payload: { runtime: { phase: 'restarting' } } };
  assert.match(await startupResponse(navigation(), body).text(), /Container runtime · Restarting/);
  const head = startupResponse(new Request(navigation(), { method: 'HEAD' }), body);
  assert.equal(await head.text(), '');
});
