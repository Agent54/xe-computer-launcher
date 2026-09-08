// Verify guest TCP transport using only the supplied app and a disposable VM.
import assert from 'node:assert/strict';
import { resolve, join } from 'node:path';

assert(Deno.args.length === 1, 'Pass the path to Xe Launcher.app');
const bundle = resolve(Deno.args[0]);
const helpers = join(bundle, 'Contents/Helpers/SmolRuntime');
const resources = join(bundle, 'Contents/Resources/SmolRuntime');
const root = await Deno.makeTempDir({ dir: '/tmp', prefix: 'xe-smol-' });
const name = 'xe-routing-test';
const env = {
  HOME: join(root, 'home'), PATH: '/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR: root,
  SMOLVM_DATA_DIR: join(root, 'data'), SMOLVM_LIB_DIR: join(helpers, 'lib'),
  DYLD_LIBRARY_PATH: join(helpers, 'lib'), SMOLVM_AGENT_ROOTFS_TAR: join(resources, 'agent-rootfs.tar'),
};
const decoder = new TextDecoder();
const encoder = new TextEncoder();
async function run(args: string[], options: { input?: string; check?: boolean; timeout?: number } = {}) {
  const process = new Deno.Command(join(helpers, 'smolvm-bin'), {
    args: ['machine', ...args], clearEnv: true, env,
    stdin: options.input === undefined ? 'null' : 'piped', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const timer = setTimeout(() => { try { process.kill('SIGKILL'); } catch { /* exited */ } }, options.timeout ?? 120000);
  try {
    if (options.input !== undefined) {
      const writer = process.stdin.getWriter();
      await writer.write(encoder.encode(options.input));
      await writer.close();
    }
    const output = await process.output();
    if (options.check !== false) assert(output.success, `${args.join(' ')}: ${decoder.decode(output.stderr)}${decoder.decode(output.stdout)}`);
    return { ...output, text: decoder.decode(output.stdout) };
  } finally { clearTimeout(timer); }
}
async function checkTransport() {
  // The pinned image includes BusyBox nc, but not its httpd applet.
  await run(['exec', '--name', name, '--detach', '--', '/bin/sh', '-c',
    "while true; do printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 13\\r\\nConnection: close\\r\\n\\r\\nxe-routing-ok' | /bin/busybox nc -l -p 18765; done"]);
  let ready = false;
  for (let attempt = 0; attempt < 20; attempt++) {
    const probe = await run(['exec', '--name', name, '--', '/bin/busybox', 'wget', '-q', '-O', '-', 'http://127.0.0.1:18765/'], { check: false, timeout: 10000 });
    if (probe.success && probe.text === 'xe-routing-ok') { ready = true; break; }
    await new Promise(r => setTimeout(r, 200));
  }
  assert(ready, 'Guest HTTP fixture unavailable');
  const response = await run(['exec', '--name', name, '-i', '--', '/bin/busybox', 'nc', '127.0.0.1', '18765'], {
    input: 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n', timeout: 20000,
  });
  assert(response.text.includes('200 OK') && response.text.endsWith('xe-routing-ok'), response.text);
}
try {
  const templates = join(env.HOME, '.smolvm');
  await Deno.mkdir(templates, { recursive: true });
  for (const filename of ['storage-template.ext4.zst', 'overlay-template.ext4.zst']) {
    await Deno.copyFile(join(resources, filename), join(templates, filename));
  }
  console.log('Creating an isolated VM from the bundled artifact');
  await run(['create', '--name', name, '--from', join(resources, 'docker-compose.smolmachine'), '--net-backend', 'virtio-net']);
  await run(['start', '--name', name]);
  await checkTransport();
  console.log('PASS: bundled SmolVM transports HTTP to a guest TCP port');
  await run(['stop', '--name', name]);
  await run(['start', '--name', name]);
  await checkTransport();
  console.log('PASS: guest TCP transport recovers after VM restart');
} finally {
  await run(['stop', '--name', name], { check: false, timeout: 45000 });
  await run(['delete', '--name', name, '--force'], { check: false, timeout: 45000 });
  await Deno.remove(root, { recursive: true });
}
