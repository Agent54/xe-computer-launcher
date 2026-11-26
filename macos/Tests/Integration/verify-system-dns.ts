// Exercise DNS mode switching with an isolated VM, keeping all state here.
// deno run --allow-read --allow-write --allow-env --allow-run Tests/Integration/verify-system-dns.ts /path/to/smolvm /path/to/SmolRuntime
import assert from 'node:assert/strict';
import { resolve, join } from 'node:path';

assert(Deno.args.length === 2, 'Pass the smol executable and staged SmolRuntime directory');
const executable = resolve(Deno.args[0]);
const runtime = resolve(Deno.args[1]);
const build = resolve(import.meta.dirname!, '../../.build');
await Deno.mkdir(build, { recursive: true });
const root = await Deno.makeTempDir({ dir: build, prefix: 'dns-' });
// libkrun's Unix socket paths must fit sun_path. Only this short symlink lives
// in /tmp; VM disks, logs, and configuration remain in the workspace.
const alias = `/tmp/xd-${crypto.randomUUID().slice(0, 8)}`;
await Deno.symlink(root, alias);
const name = 'dns';
const env = {
  HOME: join(alias, 'h'), PATH: '/usr/bin:/bin:/usr/sbin:/sbin', TMPDIR: alias,
  SMOLVM_DATA_DIR: join(alias, 'd'), SMOLVM_LIB_DIR: join(runtime, 'lib'),
  DYLD_LIBRARY_PATH: join(runtime, 'lib'), SMOLVM_AGENT_ROOTFS: join(runtime, 'agent-rootfs'),
};
const decoder = new TextDecoder();
async function run(args: string[], check = true, timeout = 90000) {
  const child = new Deno.Command(executable, {
    args: ['machine', ...args], clearEnv: true, env,
    stdin: 'null', stdout: 'piped', stderr: 'piped',
  }).spawn();
  const timer = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* already exited */ } }, timeout);
  try {
    const output = await child.output();
    const text = decoder.decode(output.stdout) + decoder.decode(output.stderr);
    if (check) assert(output.success, `${args.join(' ')}:\n${text}`);
    return { ...output, text };
  } finally { clearTimeout(timer); }
}

try {
  const templates = join(env.HOME, '.smolvm');
  await Deno.mkdir(templates, { recursive: true });
  for (const file of ['storage-template.ext4.zst', 'overlay-template.ext4.zst']) {
    await Deno.symlink(join(runtime, file), join(templates, file));
  }
  await run(['create', '--name', name, '--net', '--net-backend', 'virtio-net', '--mem', '2048']);
  await run(['start', '--name', name]);
  const first = await run(['exec', '--name', name, '--', '/bin/sh', '-c',
    'cat /etc/resolv.conf; nslookup example.com']);
  assert(first.text.includes('100.96.0.1'), first.text);
  console.log('PASS: default DNS resolves through the guest gateway and host system resolver');
  await run(['stop', '--name', name]);
  // An unused loopback address avoids networks/VPNs that intercept every
  // outbound UDP/53 destination, including documentation-only public IPs.
  await run(['update', '--name', name, '--dns', '127.255.255.254']);
  await run(['start', '--name', name]);
  const blocked = await run(['exec', '--name', name, '--', '/bin/busybox', 'timeout', '8',
    'nslookup', 'example.com'], false, 20000);
  assert(!blocked.success, `An unreachable explicit resolver must not fall back to system/public DNS:\n${blocked.text}`);
  console.log('PASS: custom DNS is honored without fallback');
  await run(['stop', '--name', name]);
  await run(['update', '--name', name, '--system-dns']);
  await run(['start', '--name', name]);
  await run(['exec', '--name', name, '--', '/bin/busybox', 'nslookup', 'example.com']);
  console.log('PASS: clearing custom DNS restores system resolution on the existing VM');
} finally {
  await run(['stop', '--name', name], false, 45000);
  await run(['delete', '--name', name, '--force'], false, 45000);
  await Deno.remove(root, { recursive: true });
  await Deno.remove(alias);
}
