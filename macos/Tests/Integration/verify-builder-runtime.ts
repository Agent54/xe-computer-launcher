// Exercise bundled engines and byte integrity through a disposable VM's socket.
// No retries: a single truncated/corrupt upload fails the run and preserves logs.
// Use --baseline to compare socket uploads against an older bundle.
import { strict as assert } from "node:assert";
import { Buffer } from "node:buffer";
import { createHash, randomBytes } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { gzipSync } from "node:zlib";

const { values: options, positionals } = parseArgs({
  args: Deno.args, allowPositionals: true,
  options: { artifact: { type: "string" }, baseline: { type: "boolean", default: false } },
});
assert(positionals.length === 1, "Usage: verify-builder-runtime.ts BUNDLE [--artifact PATH] [--baseline]");
const bundle = resolve(positionals[0]);
const state = resolve(import.meta.dirname!, "../../.build/builder-runtime-tests");
await Deno.mkdir(state, { recursive: true });
const root = await Deno.makeTempDir({ prefix: "run-", dir: state });
// macOS Unix sockets have a 104-byte limit; only the short symlink is in /tmp.
const shortParent = await Deno.makeTempDir({ prefix: "xe-build-", dir: "/tmp" });
const short = join(shortParent, "s");
await Deno.symlink(root, short);
const helpers = join(bundle, "Contents/Helpers/SmolRuntime");
const resources = join(bundle, "Contents/Resources/SmolRuntime");
const tools = join(bundle, "Contents/Resources/ContainerTools");
const plugin = join(tools, "cli-plugins/docker-buildx");
const socketPath = join(short, "docker.sock");
const routerSocket = join(short, "workerd.sock");
const stacks = join(root, "stacks");
await Deno.mkdir(stacks);
await Deno.writeTextFile(join(stacks, "index.html"), "host-file-before-restart");
const home = join(root, "home");
await Deno.mkdir(join(home, ".smolvm"), { recursive: true });
for (const name of ["storage-template.ext4.zst", "overlay-template.ext4.zst"]) {
  await Deno.copyFile(join(resources, name), join(home, ".smolvm", name));
}
const env: Record<string, string> = {
  HOME: home, PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
  SMOLVM_DATA_DIR: join(short, "data"), SMOLVM_LIB_DIR: join(helpers, "lib"),
  DYLD_LIBRARY_PATH: join(helpers, "lib"), SMOLVM_AGENT_ROOTFS_TAR: join(resources, "agent-rootfs.tar"),
};
const decoder = new TextDecoder();
async function run(command: string[], environment = env, check = true) {
  const result = await new Deno.Command(command[0], {
    args: command.slice(1), clearEnv: true, env: environment, stdout: "piped", stderr: "piped",
    signal: AbortSignal.timeout(240_000),
  }).output();
  const output = decoder.decode(result.stdout) + decoder.decode(result.stderr);
  await Deno.writeTextFile(join(root, "commands.log"), `$ ${command.join(" ")}\n${output}\n`, { append: true });
  if (check) assert(result.success, output.slice(-8000));
  return output;
}
const machine = (...args: string[]) => run([join(helpers, "smolvm-bin"), "machine", ...args]);
const guest = (...args: string[]) => machine("exec", "--name", "xe-builder-test", "--", ...args);

async function request(method: string, path: string, body?: Buffer | Iterable<Buffer>, headers = {}): Promise<Buffer> {
  using client = Deno.createHttpClient({ proxy: { transport: "unix", path: socketPath }, http2: false });
  const response = await fetch(`http://localhost${path}`, {
    client, method, headers, signal: AbortSignal.timeout(120_000),
    body: body === undefined ? undefined : Buffer.isBuffer(body) ? new Uint8Array(body) : ReadableStream.from(body),
  });
  const data = Buffer.from(await response.arrayBuffer());
  assert(response.ok, `${method} ${path}: ${response.status}: ${data.subarray(0, 2000)}`);
  return data;
}
const json = async (path: string) => JSON.parse((await request("GET", path)).toString());
// Workerd requires origin-form HTTP requests. Curl's Unix transport sends that
// form, matching the launcher; Deno's proxy transport sends absolute-form URLs.
const routerRequest = (path: string, headers: Record<string, string> = {}, origin = "http://localhost") =>
  run(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--max-time", "120", "--unix-socket", routerSocket,
    ...Object.entries(headers).flatMap(([key, value]) => ["--header", `${key}: ${value}`]), `${origin}${path}`]);
async function ready() {
  let lastError: unknown;
  for (let attempt = 0; attempt < 90; attempt++) {
    try {
      if ((await request("GET", "/_ping")).toString() === "OK") {
        if (!options.baseline) assert.equal(await routerRequest("/__xe_router_health"), "ready");
        return;
      }
    } catch (error) {
      // Fetch reports connection failures as TypeError while Docker starts.
      // Uploads themselves are never retried; preserve the readiness error.
      if (!(error instanceof TypeError)) throw error;
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error("Docker did not become ready", { cause: lastError });
}
async function tar(...args: string[]) {
  const result = await new Deno.Command("/usr/bin/tar", { args, stdout: "piped", stderr: "piped" }).output();
  assert(result.success, decoder.decode(result.stderr));
  return Buffer.from(result.stdout);
}
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const uploads = join(root, "uploads");
await Deno.mkdir(uploads);
async function checkUpload(index: number) {
  // Cross gzip, HTTP chunk, vsock buffer and 1 MiB boundaries. Random data
  // prevents compression from reducing this to a tiny transport test.
  const size = [65537, 1048577, 64 * 1024 * 1024 + 17][index % 3];
  const payload = randomBytes(size);
  await Deno.writeFile(join(uploads, "payload.bin"), payload);
  let body: Buffer = await tar("-cf", "-", "-C", uploads, "payload.bin");
  const compressed = index % 2 === 0;
  if (compressed) body = gzipSync(body);
  const chunked = index % 4 < 2;
  const headers: Record<string, string> = { "Content-Type": "application/x-tar" };
  function* chunks() {
    const sizes = [7, 4093, 65537, 131071];
    for (let offset = 0; offset < body.length;) {
      const amount = sizes[Math.floor(offset / 7) % sizes.length];
      yield body.subarray(offset, offset + amount);
      offset += amount;
    }
  }
  if (!chunked) headers["Content-Length"] = String(body.length);
  // Import uses Docker's tar/gzip reader but does not depend on the legacy
  // builder remaining available in newer Engine versions.
  const output = await request("POST", "/v1.51/images/create?fromSrc=-&repo=xe-upload-probe", chunked ? chunks() : body, headers);
  for (const line of output.toString().trim().split("\n")) {
    const message = JSON.parse(line);
    assert(!message.error, message.error);
  }
  const image = (await json("/v1.51/images/xe-upload-probe/json")).Id;
  try {
    const archive = join(uploads, "export.tar");
    await Deno.writeFile(archive, await request("GET", `/v1.51/images/${image}/get`));
    const manifest = JSON.parse((await tar("-xOf", archive, "manifest.json")).toString());
    const layer = join(uploads, "layer.tar");
    await Deno.writeFile(layer, await tar("-xOf", archive, manifest[0].Layers.at(-1)));
    assert.equal(sha256(await tar("-xOf", layer, "payload.bin")), sha256(payload), `Upload ${index}: payload checksum mismatch`);
  } finally {
    await request("DELETE", "/v1.51/images/xe-upload-probe?force=1");
  }
  console.log(`PASS upload ${index}: ${size} bytes, gzip=${compressed}, chunked=${chunked}`);
}

let created = false;
try {
  const args = ["create", "--name", "xe-builder-test", "--from", options.artifact ?? join(resources, "docker-compose.smolmachine"),
    "--net-backend", "virtio-net", "--mem", "6144", "--cpus", "4", "--storage", "20",
    "--expose-socket", `/var/run/docker.sock:${socketPath}`];
  if (!options.baseline) {
    args.push("--volume", `${stacks}:/stacks:rw`, "--expose-socket", `/run/xe-router/workerd.sock:${routerSocket}`);
    const metadata = await Deno.readTextFile(options.artifact ? `${options.artifact}.builder.lock` : join(resources, "Builder.lock"));
    assert(metadata.includes("XE_RUNTIME_FORMAT=xe-launcher-1\n"), "Expected the launcher-derived image");
    if (!options.artifact) await assert.rejects(() => Deno.stat(join(bundle, "Contents/Resources/GuestWorker")), Deno.errors.NotFound);
  }
  await machine(...args);
  created = true;
  let started = performance.now();
  await machine("start", "--name", "xe-builder-test");
  await ready();
  console.log(`VM Docker ready in ${((performance.now() - started) / 1000).toFixed(2)}s`);
  const version = (await json("/version")).Version;
  console.log(`Docker ${version}; diagnostics: ${root}`);
  const checkStorage = () => guest("sh", "-ec",
    'grep -Eq " /storage .* - ext4 " /proc/self/mountinfo; ' +
    'test -d /storage/docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots; ' +
    'test "$(stat -c %d /storage/docker/containerd/daemon)" = "$(stat -c %d /storage)"');
  if (!options.baseline) {
    const info = await json("/info");
    assert.equal(info.Driver, "overlayfs");
    assert.equal(Object.fromEntries(info.DriverStatus)["driver-type"], "io.containerd.snapshotter.v1");
    await checkStorage();
    assert.equal(info.LoggingDriver, "local");
    await guest("sh", "-ec", 'test -x /opt/xe/guest-worker/workerd; ' +
      '! grep -Eq " /(etc/docker|opt/xe/guest-worker|opt/image-router|opt/image-recipe) " /proc/self/mountinfo; ' +
      'test "$(cat /stacks/index.html)" = host-file-before-restart; ' +
      '! echo "$PATH" | grep -q /etc/docker/startup; ' +
      '! grep -q "find /run /var/run" /usr/local/bin/dockerd-entrypoint.sh');
    console.log("PASS image-owned router and configuration; host stacks mount and both exposed sockets work");
    console.log("PASS containerd image store uses the persistent ext4 disk");
  }
  for (let index = 0; index < 12; index++) await checkUpload(index);
  if (!options.baseline) {
    const values = Object.fromEntries((await Deno.readTextFile(join(tools, "ContainerTools.lock"))).trim().split("\n").map((line) => line.split("=")));
    assert.equal(version, values.DOCKER_VERSION);
    const clientEnv = { ...env, DOCKER_HOST: `unix://${socketPath}`, DOCKER_CONFIG: join(root, "docker-client"),
      BUILDX_CONFIG: join(root, "docker-client/buildx"), DOCKER_BUILDKIT: "1", BUILDX_BUILDER: "xe",
      XE_SMOLVM_HOME: home, XE_SMOLVM_DATA_DIR: env.SMOLVM_DATA_DIR, XE_SMOLVM_MACHINE: "xe-builder-test" };
    await Deno.mkdir(clientEnv.DOCKER_CONFIG);
    await Deno.writeTextFile(join(clientEnv.DOCKER_CONFIG, "config.json"), JSON.stringify({ cliPluginsExtraDirs: [dirname(plugin)] }));
    await run([plugin, "version"], clientEnv);
    await run([plugin, "docker-cli-plugin-metadata"], clientEnv);
    const maintenance = () => guest("/usr/local/share/xe-builder/cache.sh", "prune", "--builder", "xe", "--force");
    await maintenance();
    assert.deepEqual(await json("/v1.51/containers/json?all=1"), []);
    assert.deepEqual(await json("/v1.51/images/json"), []);
    console.log("PASS idle VM, plugin discovery and maintenance do not import or start BuildKit");
    // Serve a real host-mounted file through Docker's container network and the
    // exposed router socket. All binaries come from the guest; no registry pull.
    const routeContext = join(root, "route-context");
    await Deno.mkdir(routeContext);
    for (const [source, name] of [["/bin/busybox", "busybox"], ["/lib/ld-musl-aarch64.so.1", "ld-musl-aarch64.so.1"]]) {
      await machine("cp", `xe-builder-test:${source}`, join(routeContext, name));
    }
    await Deno.copyFile(resolve(import.meta.dirname!, "../Fixtures/route-probe.capnp"), join(routeContext, "server.capnp"));
    await Deno.writeTextFile(join(routeContext, "Dockerfile"), 'FROM scratch\nCOPY --chmod=755 busybox /bin/busybox\nCOPY --chmod=755 ld-musl-aarch64.so.1 /lib/ld-musl-aarch64.so.1\nCOPY server.capnp /server.capnp\nENTRYPOINT ["/runtime/lib/ld-linux-aarch64.so.1", "--library-path", "/runtime/lib", "/runtime/workerd", "serve", "/server.capnp"]\n');
    await run([plugin, "build", "--builder", "xe", "--load", "--tag", "xe-router-probe", routeContext], clientEnv);
    const routeContainer = JSON.parse((await request("POST", "/v1.51/containers/create", Buffer.from(JSON.stringify({
      Image: "xe-router-probe", ExposedPorts: { "8080/tcp": {} },
      Healthcheck: { Test: ["CMD", "/bin/busybox", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/index.html"], Interval: 1_000_000_000, Timeout: 1_000_000_000, Retries: 5 },
      Labels: { "com.docker.compose.project": "route-probe", "com.docker.compose.service": "probe" },
      HostConfig: { Binds: ["/stacks:/www:ro", "/opt/xe/guest-worker:/runtime:ro"], PortBindings: { "8080/tcp": [{ HostPort: "18080" }] } },
    })), { "Content-Type": "application/json" })).toString()).Id;
    const checkRoute = async (expected: string) => {
      await request("POST", `/v1.51/containers/${routeContainer}/start`);
      let healthy = false;
      for (let attempt = 0; attempt < 60; attempt++) {
        const container = await json(`/v1.51/containers/${routeContainer}/json`);
        if (container.State.Health?.Status === "healthy") { healthy = true; break; }
        if (!container.State.Running || container.State.Health?.Status === "unhealthy") break;
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
      assert(healthy, await guest("docker", "logs", routeContainer));
      assert.equal(await routerRequest("/index.html", {
        "x-xe-container-id": routeContainer, "x-xe-target-port": "8080", "x-xe-published-port": "18080",
      }, "http://probe.localhost"), expected);
      console.log("PASS host → router socket → container → host-mounted file");
    };
    await checkRoute("host-file-before-restart");
    const context = join(root, "context");
    await Deno.mkdir(context);
    await Deno.writeTextFile(join(context, "Dockerfile"), "FROM scratch\nCOPY payload.bin /payload.bin\n");
    for (let boot = 0; boot < 2; boot++) {
      if (boot) {
        await Deno.writeTextFile(join(stacks, "index.html"), "host-file-after-restart");
        await machine("stop", "--name", "xe-builder-test");
        started = performance.now();
        await machine("start", "--name", "xe-builder-test");
        await ready();
        assert.equal((await json(`/v1.51/containers/${routeContainer}/json`)).State.Running, false);
        await checkRoute("host-file-after-restart");
        for (const architecture of ["arm64", "amd64"]) {
          const platform = encodeURIComponent(JSON.stringify({ os: "linux", architecture }));
          assert.equal((await json(`/v1.51/images/xe-persistence-probe/json?platform=${platform}`)).Architecture, architecture);
        }
        console.log("PASS both platforms of the loaded image survive VM restart");
        await checkStorage();
        const builder = await json("/v1.51/containers/buildx_buildkit_xe0/json");
        assert.equal(builder.State.Running, false);
        assert.equal(builder.HostConfig.RestartPolicy.Name, "no");
        await maintenance();
        assert.equal((await json("/v1.51/containers/buildx_buildkit_xe0/json")).State.Running, false);
        console.log(`PASS restart and maintenance leave BuildKit stopped (${((performance.now() - started) / 1000).toFixed(2)}s)`);
      }
      for (let attempt = 0; attempt < 3; attempt++) {
        const payload = randomBytes(8 * 1024 * 1024 + 17);
        await Deno.writeFile(join(context, "payload.bin"), payload);
        const output = join(root, `output-${boot}-${attempt}`);
        await run([plugin, "build", "--builder", "xe", "--progress", "plain", "--output", `type=local,dest=${output}`, context], clientEnv);
        assert.equal(sha256(await Deno.readFile(join(output, "payload.bin"))), sha256(payload), "BuildKit output is corrupted");
        console.log(`PASS BuildKit upload, boot=${boot}, attempt=${attempt}`);
      }
      if (!boot) {
        await run([plugin, "build", "--builder", "xe", "--platform", "linux/arm64,linux/amd64", "--provenance=mode=min", "--load", "--tag", "xe-persistence-probe", context], clientEnv);
        console.log("PASS multi-platform image with provenance loaded into containerd");
      }
    }
    await run([plugin, "build", "--builder", "xe", "--load", "--tag", "xe-builder-probe", context], clientEnv);
    await json("/v1.51/images/xe-builder-probe/json");
    console.log("PASS BuildKit result loaded into Docker");
    // COPY --link requires BuildKit, giving positive evidence beyond optional labels.
    await Deno.writeTextFile(join(context, "Dockerfile"), "FROM scratch\nCOPY --link payload.bin /payload.bin\n");
    await Deno.writeTextFile(join(context, "compose.yaml"), "name: xe-build-probe\nservices:\n  probe:\n    build: .\n    image: xe-compose-build-probe\n");
    const compose = [join(bundle, "Contents/Helpers/docker-compose"), "-f", join(context, "compose.yaml"), "build"];
    await run(compose, clientEnv);
    const image = await json("/v1.51/images/xe-compose-build-probe/json");
    assert.notEqual(image.Config.Labels?.["com.docker.compose.image.builder"], "classic");
    console.log("PASS bundled Compose uses BuildKit");
    assert((await guest("/usr/local/bin/docker", "exec", "buildx_buildkit_xe0", "buildkitd", "--version")).includes(`v${values.BUILDKIT_VERSION} `));
    assert((await run(compose, { ...clientEnv, DOCKER_BUILDKIT: "0" }, false)).includes("classic builds are disabled"));
    console.log("PASS Compose rejects the classic builder");
    await guest("pkill", "-TERM", "-f", "^/opt/xe/guest-worker/lib/ld-linux-aarch64.so.1 ");
    let exited = false;
    for (let attempt = 0; attempt < 60; attempt++) {
      const status = JSON.parse(await machine("status", "--name", "xe-builder-test", "--json"));
      if (status.workload?.state === "exited") { exited = true; break; }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    assert(exited, "Router failure must stop the workload for the host supervisor to observe");
    await machine("stop", "--name", "xe-builder-test");
    await machine("start", "--name", "xe-builder-test");
    await ready();
    assert.equal((await json("/v1.51/containers/buildx_buildkit_xe0/json")).State.Running, false);
    console.log("PASS router failure exits the workload; VM restart restores routing without host deployment");
  }
  console.log("PASS: no retries or corrupted uploads");
} finally {
  try {
    if (created) await machine("stop", "--name", "xe-builder-test");
  } finally {
    await Deno.remove(short);
    await Deno.remove(shortParent);
    console.log(`Preserved disposable VM and diagnostics in ${root}`);
  }
}
